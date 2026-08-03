-- =============================================================================
-- PATCH: fix "violates foreign key constraint final_candidates_question_id_fkey"
-- in fn_archive_and_reset
--
-- final_candidates.question_id references questions(id), but the previous
-- version deleted `questions` before `final_candidates` — so any question
-- that made it into the final round (which, after a completed cycle, is
-- essentially always at least one per grade) blocked the delete.
--
-- Fix: delete in true dependency order, innermost table first:
--   final_votes  (references final_candidates)
--   final_candidates (references questions)
--   questions
--   votes / rounds have no other tables depending on them, so their
--   position relative to each other doesn't matter, but they still need
--   to come after anything that references THEM (votes references
--   questions too, so it's kept first, before questions is touched).
--
-- Run this once in the Supabase SQL editor; it replaces the whole function.
-- =============================================================================

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
  -- Deleted in true dependency order (innermost/referencing table first),
  -- with `where true` so each unqualified full-table delete satisfies the
  -- WHERE-clause guardrail:
  --   final_votes       -> references final_candidates
  --   final_candidates  -> references questions
  --   votes             -> references questions
  --   questions         (now safe: nothing still points at it)
  --   rounds            (nothing references it)
  delete from final_votes where true;
  delete from final_candidates where true;
  delete from votes where true;
  delete from questions where true;
  update final_round set status = 'not_started', started_at = null, ended_at = null where id = 1;
  delete from rounds where true;
  update grade_status set voting_open = true, ended_at = null;
end;
$$;
