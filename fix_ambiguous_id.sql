-- =============================================================================
-- PATCH: fix "column reference "id" is ambiguous" in fn_list_final_candidates
--
-- This function is declared `returns table (id bigint, question varchar)`,
-- which makes `id` an output variable in scope for the whole function body
-- (standard PL/pgSQL behavior for RETURNS TABLE/OUT parameters). The line
-- `where id = 1` was meant to reference final_round.id, but with an `id`
-- variable also in scope, Postgres can't tell which one you mean — hence
-- the ambiguity error. Every other function in the schema already qualifies
-- its column references (e.g. q.id), which is why this is the only one
-- that hit it.
--
-- Fix: qualify it as final_round.id, same as everywhere else. Run this
-- once in the Supabase SQL editor.
-- =============================================================================

create or replace function fn_list_final_candidates()
returns table (id bigint, question varchar)
language plpgsql
security definer
as $$
begin
  if (select status from final_round where final_round.id = 1) <> 'active' then
    return;
  end if;
  return query select fc.id, fc.question from final_candidates fc order by random();
end;
$$;
