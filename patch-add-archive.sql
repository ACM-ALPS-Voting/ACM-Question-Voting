-- ============================================================================
-- PATCH: add the archive feature + archive-and-reset
-- ============================================================================
-- Run this in Supabase's SQL Editor. It only ADDS new objects (a table, a
-- sequence, and three functions) — it doesn't touch anything you already
-- have, so it's safe to run on your live database.
-- ============================================================================

-- ARCHIVE — snapshot of the top 3 questions per grade (plus FINAL, if that
-- round completed) at the moment the teacher ends a full question-board
-- cycle. Saving to this table is paired with wiping every other table so
-- the board is ready to start fresh.
-- ============================================================================

-- Gives every row saved by one archiving action the same shared number, so
-- "show me this one archive" can look them up as a single unit without
-- relying on exact-timestamp matching (which is fragile across JS <-> SQL).
create sequence archive_batch_seq;

create table archive (
  id            bigint generated always as identity primary key,
  archive_batch bigint       not null,
  archived_at   timestamptz  not null,
  grade         varchar(5)   not null check (grade in ('3','4','5','6','FINAL')),
  rank          int          not null check (rank between 1 and 3),
  student_id    varchar(30)  not null,
  question      varchar(200) not null,
  votes         bigint       not null default 0,
  unique (archive_batch, grade, rank)
);

alter table archive enable row level security;
-- Same pattern as every other table: no policies, access only via functions
-- below. (fn_get_archive_dates / fn_get_archive don't require a passphrase
-- since archive results aren't sensitive — see fn_get_final_results for the
-- same reasoning applied to final-vote results.)


-- ADMIN FUNCTION: fn_archive_and_reset
-- Saves the top 3 questions per grade (and FINAL, if that round completed)
-- into the archive, then wipes questions/votes/rounds/final-vote data and
-- reopens all four grades so the board is ready for the next cycle.
create or replace function fn_archive_and_reset(p_passphrase text)
returns void
language plpgsql
security definer
as $$
declare
  v_grade        char(1);
  v_batch        bigint;
  v_now          timestamptz := now();
  v_final_status text;
begin
  perform fn_check_admin(p_passphrase);

  if exists (select 1 from grade_status where voting_open = true) then
    raise exception 'All four grades must have voting ended before archiving.';
  end if;

  select status into v_final_status from final_round where id = 1;
  if v_final_status = 'active' then
    raise exception 'The final vote is still active — end it first, or its results will be lost.';
  end if;

  v_batch := nextval('archive_batch_seq');

  -- Top 3 per grade, by all-time total votes (ties broken by earliest submission)
  for v_grade in select grade from grade_status order by grade loop
    insert into archive (archive_batch, archived_at, grade, rank, student_id, question, votes)
    select v_batch, v_now, v_grade, ranked.rn, ranked.student_id, ranked.question, ranked.votes
    from (
      select
        q.student_id,
        q.question,
        coalesce((select count(*) from votes v where v.question_id = q.id), 0) as votes,
        row_number() over (
          order by coalesce((select count(*) from votes v where v.question_id = q.id), 0) desc,
                   q.created_at asc
        ) as rn
      from questions q
      where q.grade = v_grade
    ) ranked
    where ranked.rn <= 3;
  end loop;

  -- Top 3 from the final vote, only if one actually completed
  if v_final_status = 'ended' then
    insert into archive (archive_batch, archived_at, grade, rank, student_id, question, votes)
    select v_batch, v_now, 'FINAL', ranked.rn, ranked.student_id, ranked.question, ranked.votes
    from (
      select
        fc.student_id,
        fc.question,
        coalesce((select count(*) from final_votes fv where fv.candidate_id = fc.id), 0) as votes,
        row_number() over (
          order by coalesce((select count(*) from final_votes fv where fv.candidate_id = fc.id), 0) desc
        ) as rn
      from final_candidates fc
    ) ranked
    where ranked.rn <= 3;
  end if;

  -- Wipe everything else so the board is ready for the next cycle.
  -- Order matters here because of foreign keys: votes before questions,
  -- final_votes before final_candidates.
  delete from votes;
  delete from questions;
  delete from final_votes;
  delete from final_candidates;
  update final_round set status = 'not_started', started_at = null, ended_at = null where id = 1;
  delete from rounds;
  update grade_status set voting_open = true, ended_at = null;
end;
$$;


-- PUBLIC FUNCTION: fn_get_archive_dates
-- Called by archive.html to populate the date picker.
create or replace function fn_get_archive_dates()
returns table (archive_batch bigint, archived_at timestamptz)
language sql
security definer
as $$
  select distinct archive_batch, archived_at from archive order by archived_at desc;
$$;


-- PUBLIC FUNCTION: fn_get_archive
-- Called by archive.html once a date is picked. Returns every grade's rows
-- together, pre-sorted for display (grade 3-6, then FINAL, rank ascending
-- within each).
create or replace function fn_get_archive(p_archive_batch bigint)
returns table (grade varchar, rank int, student_id varchar, question varchar, votes bigint)
language sql
security definer
as $$
  select grade, rank, student_id, question, votes
  from archive
  where archive_batch = p_archive_batch
  order by
    case grade when '3' then 1 when '4' then 2 when '5' then 3 when '6' then 4 when 'FINAL' then 5 else 6 end,
    rank;
$$;
