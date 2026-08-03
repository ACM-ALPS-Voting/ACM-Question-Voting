-- =============================================================================
-- fn_admin_student_lookup
--
-- Powers the "Student lookup" card on index.html (the teacher admin page).
-- Given a student ID, returns everything about that student across ALL
-- grades in a single JSON payload:
--   - questions:   what they submitted, plus how the votes it received
--                   break down round-by-round and in total
--   - votes_cast:  every vote they personally cast, one row per vote, with
--                   which question/round each one was for
--
-- Written against the real schema.sql (questions / votes / fn_check_admin),
-- not a guess — safe to run as-is.
--
-- Note: this covers regular per-grade voting only, not the one-off FINAL
-- vote (which lives in separate final_candidates/final_votes tables and
-- isn't organized "by round" the same way). Say the word if you'd like a
-- student's final-vote participation folded in too.
-- =============================================================================

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
  -- Same admin check every other admin function uses.
  perform fn_check_admin(p_passphrase);

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
              jsonb_build_object('round_number', rc.round_number, 'votes', rc.cnt)
              order by rc.round_number
            )
            from (
              select round_number, count(*) as cnt
              from votes
              where question_id = q.id
              group by round_number
            ) rc
          ), '[]'::jsonb)
        )
        order by q.grade, q.created_at
      )
      from questions q
      where q.student_id = p_student_id
    ), '[]'::jsonb),

    -- ---- every vote this student cast, across all grades and rounds ----
    'votes_cast', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'grade', v.grade,
          'round_number', v.round_number,
          'question', v.question,
          'author_student_id', q.student_id
        )
        order by v.grade, v.round_number, v.created_at
      )
      from votes v
      join questions q on q.id = v.question_id
      where v.student_id = p_student_id
    ), '[]'::jsonb)

  )
  into v_result;

  return v_result;
end;
$$;

-- Same anon-callable pattern as every other fn_* function — fn_check_admin
-- inside is what actually gates access.
grant execute on function fn_admin_student_lookup(text, text) to anon;
