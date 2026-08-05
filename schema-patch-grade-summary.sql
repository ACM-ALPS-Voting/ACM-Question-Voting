-- =============================================================================
-- PATCH: add fn_get_grade_summary (per-grade sidebar status)
-- =============================================================================
-- Adds ONE new function — no tables, no columns, nothing that could already
-- exist — so it's safe to run against your live project as-is, the same
-- way schema-patch-final-fixes.sql was.
--
-- Powers the "Grade 3: 12 submitted, 8 remaining, 34 votes cast" style
-- summary under the submissions toggle on admin.html. Returns all four
-- grades in one call (rather than one function call per grade) so the
-- sidebar can refresh with a single round trip.
-- =============================================================================

create or replace function fn_get_grade_summary(p_passphrase text)
returns table (
  grade      char(1),
  submitted  bigint,   -- every question ever submitted for this grade
  remaining  bigint,   -- of those, how many are still in the running
                        -- (not eliminated by a zero-vote round)
  votes_cast bigint     -- every vote cast for this grade, across all rounds
)
language plpgsql
security definer
as $$
begin
  perform fn_check_admin(p_passphrase);

  return query
  select
    gs.grade,
    coalesce((select count(*) from questions q
              where q.grade = gs.grade), 0) as submitted,
    coalesce((select count(*) from questions q
              where q.grade = gs.grade and q.eliminated = false), 0) as remaining,
    coalesce((select count(*) from votes v
              where v.grade = gs.grade), 0) as votes_cast
  from grade_status gs
  order by gs.grade;
end;
$$;

grant execute on function fn_get_grade_summary(text) to anon;
