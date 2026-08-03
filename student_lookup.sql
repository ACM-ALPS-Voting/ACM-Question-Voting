-- =============================================================================
-- fn_admin_student_lookup
--
-- Powers the new "Student lookup" card on index.html (the teacher admin
-- page). Given a student ID, it returns everything about that student
-- across ALL grades in a single JSON payload:
--   - questions:   what they submitted, plus how the votes it received
--                   break down round-by-round and in total
--   - votes_cast:  every vote they personally cast, one row per vote,
--                   with which question/round each one was for
--
-- ============================ READ BEFORE RUNNING ============================
-- This function was written by inferring table and column names from the
-- other RPC calls already used in index.html (fn_admin_list, fn_get_rounds,
-- fn_get_final_results, etc.) — the actual schema.sql wasn't available when
-- this was written, so the exact table/column names below are an educated
-- guess, not a certainty. Assumed shape:
--   questions(id, grade, student_id, question, eliminated, ...)
--   rounds(id, grade, round_number, ...)
--   votes(id, question_id -> questions.id, round_id -> rounds.id,
--         voter_student_id, ...)
--
-- Before running this in the Supabase SQL editor:
--   1. Check those table/column names against your real schema (Table
--      Editor, or your original schema.sql) and adjust anywhere they
--      differ — search for "TODO" below for the two spots most likely to
--      need a change.
--   2. Run a quick manual select against `votes` / `rounds` to confirm
--      how a vote is linked to its round (a round_id foreign key, as
--      assumed here, vs. a plain grade + round_number pair) and adjust
--      the two join conditions if needed.
-- ============================================================================

create or replace function fn_admin_student_lookup(
  p_passphrase text,
  p_student_id text
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_result jsonb;
begin
  -- TODO: replace this with whatever passphrase check your other fn_*
  -- functions already use (e.g. a shared helper function, or a direct
  -- comparison against a row in an admin_config/settings table). This
  -- placeholder assumes a one-row admin_config table with a "passphrase"
  -- column — swap it for the real mechanism.
  if p_passphrase is null or p_passphrase <> (select passphrase from admin_config limit 1) then
    raise exception 'Invalid passphrase';
  end if;

  select jsonb_build_object(

    -- ---- everything this student submitted, with vote counts per round ----
    'questions', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'grade', q.grade,
          'question', q.question,
          'eliminated', q.eliminated,
          'total_votes', (
            select count(*) from votes v where v.question_id = q.id
          ),
          'votes_by_round', coalesce((
            select jsonb_agg(
              jsonb_build_object('round_number', r.round_number, 'votes', round_counts.votes)
              order by r.round_number
            )
            from (
              -- TODO: if votes don't carry a round_id FK, group by
              -- (grade, round_number) directly on the votes table instead.
              select v.round_id, count(*) as votes
              from votes v
              where v.question_id = q.id
              group by v.round_id
            ) round_counts
            join rounds r on r.id = round_counts.round_id
          ), '[]'::jsonb)
        )
      )
      from questions q
      where q.student_id = p_student_id
    ), '[]'::jsonb),

    -- ---- every vote this student cast, across all grades and rounds ----
    'votes_cast', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'grade', r.grade,
          'round_number', r.round_number,
          'question', q.question,
          'author_student_id', q.student_id
        )
        order by r.grade, r.round_number
      )
      from votes v
      join rounds r on r.id = v.round_id
      join questions q on q.id = v.question_id
      where v.voter_student_id = p_student_id
    ), '[]'::jsonb)

  )
  into v_result;

  return v_result;
end;
$$;

-- Matches the anon-callable pattern the other fn_* functions use (the page
-- calls this with the public anon key, and the passphrase check inside the
-- function is what actually gates access).
grant execute on function fn_admin_student_lookup(text, text) to anon;
