-- ============================================================================
-- CLASSROOM QUESTION BOARD — DATABASE SCHEMA
-- ============================================================================
-- Run this whole file once in Supabase: Project -> SQL Editor -> New query ->
-- paste this entire file -> Run. It creates everything the three HTML pages
-- need: two data tables (as requested) plus two small helper tables, and a
-- set of functions that the pages call instead of touching tables directly.
--
-- WHY FUNCTIONS INSTEAD OF DIRECT TABLE ACCESS?
-- The three HTML pages are static files with no server behind them, so the
-- database connection info (the "anon key") is visible to anyone who views
-- the page source. To keep things safe, every table has Row Level Security
-- turned on with NO direct access rules at all — the only way in or out is
-- through the functions below, each of which checks that the request makes
-- sense (right grade, round open, correct admin passphrase, etc.) before
-- touching data. This also lets us hide student IDs and IP addresses from
-- the voting page, since it only ever asks for question text.
-- ============================================================================

-- Needed for hashing the admin passphrase (crypt / gen_salt below).
create extension if not exists pgcrypto;


-- ============================================================================
-- TABLE 1 OF 2 (as specified): questions
-- ============================================================================
create table questions (
  id           bigint generated always as identity primary key,
  grade        char(1)      not null check (grade in ('3','4','5','6')),
  student_id   varchar(30)  not null,
  question     varchar(200) not null,
  created_at   timestamptz  not null default now(),   -- "Timestamp" from the spec
  ip_address   varchar(40),                           -- "IP Address" from the spec
  eliminated   boolean      not null default false     -- true once a round ends
                                                         -- with zero votes for it
);

-- ============================================================================
-- TABLE 2 OF 2 (as specified): votes
-- ============================================================================
-- The spec's vote table is Grade / Student ID / Question. We keep exactly
-- those three columns, and add two small technical columns (question_id,
-- round_number) so the app can count votes per round and per question
-- reliably — the question TEXT alone isn't a safe way to look votes up by,
-- since two students could type near-identical questions.
create table votes (
  id            bigint generated always as identity primary key,
  grade         char(1)      not null check (grade in ('3','4','5','6')),
  student_id    varchar(30)  not null,                 -- the VOTER's student ID
  question      varchar(200) not null,                 -- snapshot of the question text
  question_id   bigint       not null references questions(id),
  round_number  int          not null,
  created_at    timestamptz  not null default now()
);

-- ============================================================================
-- SUPPORTING TABLE: rounds
-- ============================================================================
-- One row per grade, per round. Tracks whether that round is currently
-- accepting votes, how many votes each student gets in it, and when it
-- started/ended. This is what powers the "Round One / Start Round / End
-- Round" controls on the admin page.
create table rounds (
  id                 bigint generated always as identity primary key,
  grade              char(1) not null check (grade in ('3','4','5','6')),
  round_number       int     not null check (round_number between 1 and 30),
  votes_per_student  int     not null default 1 check (votes_per_student >= 1),
  status             text    not null default 'active' check (status in ('active','ended')),
  started_at         timestamptz not null default now(),
  ended_at           timestamptz,
  unique (grade, round_number)
);

-- ============================================================================
-- SUPPORTING TABLE: grade_status
-- ============================================================================
-- One row per grade. Once the teacher clicks "End Voting" for a grade,
-- voting_open flips to false and no further rounds can start for it.
create table grade_status (
  grade        char(1) primary key check (grade in ('3','4','5','6')),
  voting_open  boolean not null default true,
  ended_at     timestamptz
);
insert into grade_status (grade) values ('3'), ('4'), ('5'), ('6');

-- ============================================================================
-- SUPPORTING TABLE: admin_settings
-- ============================================================================
-- Single row holding a HASHED admin passphrase (never stored in plain text).
-- This is a lightweight lock, appropriate for a classroom tool — it is not
-- meant to withstand a determined attacker, just to keep the admin controls
-- away from students who happen to find the URL.
-- Default passphrase is 'changeme123' — CHANGE THIS (see README) before use.
create table admin_settings (
  id              int primary key default 1 check (id = 1),
  passphrase_hash text not null
);
insert into admin_settings (id, passphrase_hash)
values (1, crypt('changeme123', gen_salt('bf')));

-- ============================================================================
-- LOCK EVERYTHING DOWN
-- ============================================================================
-- RLS is ON and we deliberately create no policies, so anon/authenticated
-- roles get zero direct table access. All reads and writes happen through
-- the SECURITY DEFINER functions below, which run with the table owner's
-- privileges regardless of who calls them.
alter table questions       enable row level security;
alter table votes            enable row level security;
alter table rounds           enable row level security;
alter table grade_status     enable row level security;
alter table admin_settings   enable row level security;


-- ============================================================================
-- HELPER: fn_check_admin
-- ============================================================================
-- Every admin-only function calls this first. Raises an error (which the
-- page displays) if the passphrase is wrong.
create or replace function fn_check_admin(p_passphrase text)
returns void
language plpgsql
security definer
as $$
begin
  if not exists (
    select 1 from admin_settings
    where id = 1 and passphrase_hash = crypt(p_passphrase, passphrase_hash)
  ) then
    raise exception 'Incorrect admin passphrase.';
  end if;
end;
$$;


-- ============================================================================
-- PUBLIC FUNCTION: fn_submit_question
-- ============================================================================
-- Called by the Question Submission page. Trims and length-limits input,
-- validates the grade, and stamps the row with server time + the caller's
-- IP (the page looks the IP up itself and passes it in, since a static
-- HTML page has no server of its own to read it from).
create or replace function fn_submit_question(
  p_grade      char(1),
  p_student_id text,
  p_question   text,
  p_ip         text
)
returns void
language plpgsql
security definer
as $$
begin
  if p_grade not in ('3','4','5','6') then
    raise exception 'Grade must be 3, 4, 5, or 6.';
  end if;
  if length(trim(coalesce(p_student_id, ''))) = 0 then
    raise exception 'Student ID is required.';
  end if;
  if length(trim(coalesce(p_question, ''))) = 0 then
    raise exception 'Question text is required.';
  end if;

  insert into questions (grade, student_id, question, ip_address)
  values (
    p_grade,
    left(trim(p_student_id), 30),
    left(trim(p_question), 200),
    left(coalesce(p_ip, 'unknown'), 40)
  );
end;
$$;


-- ============================================================================
-- PUBLIC FUNCTION: fn_get_round_status
-- ============================================================================
-- Called by the Voting page to know what to show: which round number is
-- current, whether it is open for votes, and how many votes each student
-- gets. Also reports whether the grade's voting has been ended entirely.
create or replace function fn_get_round_status(p_grade char(1))
returns table (
  round_number      int,
  round_status      text,
  votes_per_student int,
  voting_open       boolean
)
language sql
security definer
as $$
  select r.round_number, r.status, r.votes_per_student, gs.voting_open
  from grade_status gs
  left join rounds r
    on r.grade = gs.grade
   and r.round_number = (select max(round_number) from rounds where grade = p_grade)
  where gs.grade = p_grade;
$$;


-- ============================================================================
-- PUBLIC FUNCTION: fn_list_open_questions
-- ============================================================================
-- Called by the Voting page. Returns ONLY id + question text (no student
-- IDs, no IP addresses) for questions still in the running for that grade,
-- in random order so ballot position doesn't bias voting.
create or replace function fn_list_open_questions(p_grade char(1))
returns table (id bigint, question varchar)
language sql
security definer
as $$
  select q.id, q.question
  from questions q
  where q.grade = p_grade and q.eliminated = false
  order by random();
$$;


-- ============================================================================
-- PUBLIC FUNCTION: fn_cast_votes
-- ============================================================================
-- Called once by the Voting page when a student submits their ballot.
-- Validates that a round is actually open, that this student hasn't
-- already voted this round, and that they didn't select more questions
-- than they're allowed — then inserts one row per vote.
create or replace function fn_cast_votes(
  p_grade        char(1),
  p_student_id   text,
  p_question_ids bigint[]
)
returns void
language plpgsql
security definer
as $$
declare
  v_round        rounds%rowtype;
  v_already      int;
  v_qid          bigint;
  v_clean_ids    bigint[];
begin
  select * into v_round
  from rounds
  where grade = p_grade and status = 'active'
  order by round_number desc
  limit 1;

  if v_round is null then
    raise exception 'Voting is not currently open for this grade.';
  end if;

  select count(*) into v_already
  from votes
  where grade = p_grade and student_id = trim(p_student_id) and round_number = v_round.round_number;

  if v_already > 0 then
    raise exception 'This Student ID has already voted in this round.';
  end if;

  -- de-duplicate in case the same question id was somehow submitted twice
  select array(select distinct unnest(p_question_ids)) into v_clean_ids;

  if v_clean_ids is null or array_length(v_clean_ids, 1) = 0 then
    raise exception 'Select at least one question.';
  end if;

  if array_length(v_clean_ids, 1) > v_round.votes_per_student then
    raise exception 'You selected more questions than allowed this round.';
  end if;

  foreach v_qid in array v_clean_ids loop
    insert into votes (grade, student_id, question_id, question, round_number)
    select p_grade, trim(p_student_id), q.id, q.question, v_round.round_number
    from questions q
    where q.id = v_qid and q.grade = p_grade and q.eliminated = false;
  end loop;
end;
$$;


-- ============================================================================
-- ADMIN FUNCTION: fn_admin_list
-- ============================================================================
-- Called by the Admin page. Returns every question for a grade with its
-- vote count in the most recent round and its all-time total, sorted the
-- way the spec asks for: most-recent-round votes first, total votes as
-- the tiebreaker.
create or replace function fn_admin_list(p_passphrase text, p_grade char(1))
returns table (
  id                bigint,
  student_id        varchar,
  question          varchar,
  eliminated        boolean,
  last_round_votes  bigint,
  total_votes       bigint
)
language plpgsql
security definer
as $$
declare
  v_last_round int;
begin
  perform fn_check_admin(p_passphrase);

  select max(round_number) into v_last_round from rounds where grade = p_grade;

  return query
  select
    q.id,
    q.student_id,
    q.question,
    q.eliminated,
    coalesce((select count(*) from votes v
              where v.question_id = q.id and v.round_number = v_last_round), 0) as last_round_votes,
    coalesce((select count(*) from votes v
              where v.question_id = q.id), 0) as total_votes
  from questions q
  where q.grade = p_grade
  order by last_round_votes desc, total_votes desc, q.created_at asc;
end;
$$;


-- ============================================================================
-- ADMIN FUNCTION: fn_get_rounds
-- ============================================================================
-- Called by the Admin page to draw the "Round One / Round Two / ..." list,
-- including how many distinct students voted and how many total votes
-- were cast in each finished round.
create or replace function fn_get_rounds(p_passphrase text, p_grade char(1))
returns table (
  round_number      int,
  round_status      text,
  votes_per_student int,
  voters            bigint,
  votes_cast        bigint,
  started_at        timestamptz,
  ended_at          timestamptz,
  voting_open       boolean
)
language plpgsql
security definer
as $$
begin
  perform fn_check_admin(p_passphrase);

  return query
  select
    r.round_number,
    r.status,
    r.votes_per_student,
    coalesce((select count(distinct v.student_id) from votes v
              where v.grade = r.grade and v.round_number = r.round_number), 0),
    coalesce((select count(*) from votes v
              where v.grade = r.grade and v.round_number = r.round_number), 0),
    r.started_at,
    r.ended_at,
    (select voting_open from grade_status where grade = r.grade)
  from rounds r
  where r.grade = p_grade
  order by r.round_number asc;
end;
$$;


-- ============================================================================
-- ADMIN FUNCTION: fn_start_round
-- ============================================================================
create or replace function fn_start_round(
  p_passphrase        text,
  p_grade              char(1),
  p_votes_per_student  int
)
returns void
language plpgsql
security definer
as $$
declare
  v_open boolean;
  v_next int;
begin
  perform fn_check_admin(p_passphrase);

  select voting_open into v_open from grade_status where grade = p_grade;
  if not v_open then
    raise exception 'Voting has already been ended for this grade.';
  end if;

  if exists (select 1 from rounds where grade = p_grade and status = 'active') then
    raise exception 'A round is already active for this grade.';
  end if;

  select coalesce(max(round_number), 0) + 1 into v_next from rounds where grade = p_grade;
  if v_next > 30 then
    raise exception 'Maximum of 30 rounds already reached for this grade.';
  end if;

  insert into rounds (grade, round_number, votes_per_student, status)
  values (p_grade, v_next, greatest(1, p_votes_per_student), 'active');
end;
$$;


-- ============================================================================
-- ADMIN FUNCTION: fn_end_round
-- ============================================================================
-- Ends the active round for a grade, then eliminates any question that
-- received zero votes THIS round so it drops off future ballots.
create or replace function fn_end_round(p_passphrase text, p_grade char(1))
returns void
language plpgsql
security definer
as $$
declare
  v_round int;
begin
  perform fn_check_admin(p_passphrase);

  select round_number into v_round from rounds where grade = p_grade and status = 'active';
  if v_round is null then
    raise exception 'No active round for this grade.';
  end if;

  update rounds set status = 'ended', ended_at = now()
  where grade = p_grade and round_number = v_round;

  update questions set eliminated = true
  where grade = p_grade
    and eliminated = false
    and id not in (
      select question_id from votes where grade = p_grade and round_number = v_round
    );
end;
$$;


-- ============================================================================
-- ADMIN FUNCTION: fn_end_voting
-- ============================================================================
-- Ends the active round (if any), closes voting for the grade entirely,
-- and returns the top 5 questions by all-time total votes.
create or replace function fn_end_voting(p_passphrase text, p_grade char(1))
returns table (student_id varchar, question varchar, total_votes bigint)
language plpgsql
security definer
as $$
begin
  perform fn_check_admin(p_passphrase);

  if exists (select 1 from rounds where grade = p_grade and status = 'active') then
    perform fn_end_round(p_passphrase, p_grade);
  end if;

  update grade_status set voting_open = false, ended_at = now() where grade = p_grade;

  return query
  select q.student_id, q.question,
         coalesce((select count(*) from votes v where v.question_id = q.id), 0) as total_votes
  from questions q
  where q.grade = p_grade
  order by total_votes desc, q.created_at asc
  limit 5;
end;
$$;


-- ============================================================================
-- ADMIN FUNCTION: fn_change_admin_passphrase
-- ============================================================================
create or replace function fn_change_admin_passphrase(p_old text, p_new text)
returns void
language plpgsql
security definer
as $$
begin
  perform fn_check_admin(p_old);
  if length(p_new) < 6 then
    raise exception 'New passphrase must be at least 6 characters.';
  end if;
  update admin_settings set passphrase_hash = crypt(p_new, gen_salt('bf')) where id = 1;
end;
$$;


-- ============================================================================
-- FINAL VOTE — pits the single top question from each grade against each
-- other. Only unlockable once every grade's voting has been ended.
-- ============================================================================

-- Singleton row tracking the final round's lifecycle.
create table final_round (
  id          int primary key default 1 check (id = 1),
  status      text not null default 'not_started' check (status in ('not_started','active','ended')),
  started_at  timestamptz,
  ended_at    timestamptz
);
insert into final_round (id) values (1);

-- One row per grade: the question that won that grade, carried into the final.
create table final_candidates (
  id           bigint generated always as identity primary key,
  grade        char(1)      not null check (grade in ('3','4','5','6')),
  question_id  bigint       not null references questions(id),
  student_id   varchar(30)  not null,
  question     varchar(200) not null,
  unique (grade)
);

-- One vote per student across the whole final round (it spans all grades,
-- so unlike the per-grade votes table there's no round_number to key on).
create table final_votes (
  id            bigint generated always as identity primary key,
  student_id    varchar(30) not null unique,
  candidate_id  bigint      not null references final_candidates(id),
  created_at    timestamptz not null default now()
);

alter table final_round      enable row level security;
alter table final_candidates enable row level security;
alter table final_votes      enable row level security;
-- Same pattern as the other tables: no policies, access only via functions.


-- ADMIN FUNCTION: fn_start_final_vote
-- Picks each grade's single highest-vote question (ties broken by whoever
-- submitted first) and opens the final round for voting.
create or replace function fn_start_final_vote(p_passphrase text)
returns void
language plpgsql
security definer
as $$
declare
  v_grade char(1);
  v_qid   bigint;
  v_sid   varchar;
  v_qtext varchar;
begin
  perform fn_check_admin(p_passphrase);

  if exists (select 1 from grade_status where voting_open = true) then
    raise exception 'All four grades must have voting ended before starting the final vote.';
  end if;

  if (select status from final_round where id = 1) <> 'not_started' then
    raise exception 'The final vote has already been started.';
  end if;

  delete from final_candidates; -- safety net, should already be empty

  for v_grade in select grade from grade_status order by grade loop
    select q.id, q.student_id, q.question into v_qid, v_sid, v_qtext
    from questions q
    where q.grade = v_grade
    order by (select count(*) from votes v where v.question_id = q.id) desc, q.created_at asc
    limit 1;

    if v_qid is not null then
      insert into final_candidates (grade, question_id, student_id, question)
      values (v_grade, v_qid, v_sid, v_qtext);
    end if;
  end loop;

  if (select count(*) from final_candidates) < 2 then
    raise exception 'Not enough questions across grades to run a final vote.';
  end if;

  update final_round set status = 'active', started_at = now() where id = 1;
end;
$$;


-- PUBLIC FUNCTION: fn_get_final_status
-- Called by the voting page (grade=FINAL) and the admin page.
create or replace function fn_get_final_status()
returns table (status text)
language sql
security definer
as $$
  select status from final_round where id = 1;
$$;


-- PUBLIC FUNCTION: fn_list_final_candidates
-- Called by the voting page once the final round is active. Only question
-- text is returned — same privacy pattern as fn_list_open_questions.
create or replace function fn_list_final_candidates()
returns table (id bigint, question varchar)
language plpgsql
security definer
as $$
begin
  if (select status from final_round where id = 1) <> 'active' then
    return;
  end if;
  return query select fc.id, fc.question from final_candidates fc order by random();
end;
$$;


-- PUBLIC FUNCTION: fn_cast_final_vote
-- One vote, one question, one Student ID for the whole final round.
create or replace function fn_cast_final_vote(p_student_id text, p_candidate_id bigint)
returns void
language plpgsql
security definer
as $$
begin
  if (select status from final_round where id = 1) <> 'active' then
    raise exception 'The final vote is not currently open.';
  end if;

  if exists (select 1 from final_votes where student_id = trim(p_student_id)) then
    raise exception 'This Student ID has already voted in the final round.';
  end if;

  if not exists (select 1 from final_candidates where id = p_candidate_id) then
    raise exception 'That is not a valid choice.';
  end if;

  insert into final_votes (student_id, candidate_id) values (trim(p_student_id), p_candidate_id);
end;
$$;


-- ADMIN FUNCTION: fn_get_final_results
create or replace function fn_get_final_results(p_passphrase text)
returns table (grade char, student_id varchar, question varchar, votes bigint)
language plpgsql
security definer
as $$
begin
  perform fn_check_admin(p_passphrase);
  return query
  select fc.grade, fc.student_id, fc.question,
         coalesce((select count(*) from final_votes fv where fv.candidate_id = fc.id), 0) as votes
  from final_candidates fc
  order by votes desc, fc.grade asc;
end;
$$;


-- ADMIN FUNCTION: fn_end_final_vote
create or replace function fn_end_final_vote(p_passphrase text)
returns void
language plpgsql
security definer
as $$
begin
  perform fn_check_admin(p_passphrase);
  if (select status from final_round where id = 1) <> 'active' then
    raise exception 'The final vote is not currently active.';
  end if;
  update final_round set status = 'ended', ended_at = now() where id = 1;
end;
$$;


-- ============================================================================
-- PERMISSIONS
-- ============================================================================
-- The pages connect using Supabase's public "anon" key, which maps to the
-- 'anon' database role. Grant it permission to CALL these functions (it
-- still has no direct table access at all).
grant execute on function fn_submit_question(char, text, text, text)              to anon;
grant execute on function fn_get_round_status(char)                                to anon;
grant execute on function fn_list_open_questions(char)                             to anon;
grant execute on function fn_cast_votes(char, text, bigint[])                      to anon;
grant execute on function fn_admin_list(text, char)                                to anon;
grant execute on function fn_get_rounds(text, char)                                to anon;
grant execute on function fn_start_round(text, char, int)                          to anon;
grant execute on function fn_end_round(text, char)                                 to anon;
grant execute on function fn_end_voting(text, char)                                to anon;
grant execute on function fn_change_admin_passphrase(text, text)                   to anon;
grant execute on function fn_start_final_vote(text)                                to anon;
grant execute on function fn_get_final_status()                                    to anon;
grant execute on function fn_list_final_candidates()                               to anon;
grant execute on function fn_cast_final_vote(text, bigint)                         to anon;
grant execute on function fn_get_final_results(text)                               to anon;
grant execute on function fn_end_final_vote(text)                                  to anon;

-- ============================================================================
-- DONE. Next step: copy your Project URL and anon public key
-- (Project Settings -> API) into the CONFIG section at the top of each of
-- the three HTML files.
-- ============================================================================
