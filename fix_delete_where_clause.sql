-- =============================================================================
-- PATCH: fix "DELETE requires a WHERE clause" errors
--
-- Your Supabase project has a guardrail (likely the pg-safeupdate style
-- protection some Supabase plans/projects enable) that rejects any DELETE
-- statement without a WHERE clause, even inside a function running as the
-- table owner. Two of the original functions had unqualified DELETEs that
-- were only ever meant to clear an entire table:
--   - fn_start_final_vote: `delete from final_candidates;`
--   - fn_archive_and_reset: five separate full-table deletes
--
-- This patch adds `where true` to each — functionally identical (still
-- deletes every row) but satisfies the WHERE-clause requirement. Run this
-- whole file once in the Supabase SQL editor; `create or replace function`
-- safely overwrites the existing versions in place.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- fn_start_final_vote
-- ----------------------------------------------------------------------------
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

  delete from final_candidates where true; -- safety net, should already be empty

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


-- ----------------------------------------------------------------------------
-- fn_archive_and_reset
-- Same fix applied to its five full-table deletes, so "Archive & reset" on
-- the admin page doesn't hit the same error later.
-- ----------------------------------------------------------------------------
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
  -- final_votes before final_candidates. `where true` added to each so
  -- these unqualified full-table deletes pass the WHERE-clause guardrail.
  delete from votes where true;
  delete from questions where true;
  delete from final_votes where true;
  delete from final_candidates where true;
  update final_round set status = 'not_started', started_at = null, ended_at = null where id = 1;
  delete from rounds where true;
  update grade_status set voting_open = true, ended_at = null;
end;
$$;
