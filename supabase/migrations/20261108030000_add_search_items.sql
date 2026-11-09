-- Jobs-list search (2026-11-08): a tap-to-search box on the Jobs list, backed by this RPC
-- instead of loading every item client-side and filtering in memory -- see PROGRESS.md.
-- security invoker, same as the other public RPCs here: items_select RLS already scopes rows
-- to the caller's account, so there's no need to re-check access here.
--
-- Matches p_query (case-insensitive substring) against:
--   - every *value* in the item's data jsonb (not the raw JSON text, so stray braces/quotes/key
--     names never cause a false match -- field-name-agnostic, so it works across workflows with
--     different checklist fields without hard-coding any of them)
--   - the item's current stage title
--   - the item's 1-based job number (its position among the workflow's items ordered by
--     created_at -- the same number WorkflowApiClient/WorkflowDetail.razor's JobNumber() derives
--     client-side today), matched as an exact string so "12" doesn't also match "120"
create or replace function public.search_items(p_workflow_id uuid, p_query text)
returns table (
  id uuid,
  stage_id uuid,
  data jsonb,
  created_at timestamptz,
  job_number bigint
)
language sql
stable
security invoker
set search_path = public
as $$
  with numbered as (
    select
      i.id,
      i.stage_id,
      i.data,
      i.created_at,
      row_number() over (order by i.created_at) as job_number,
      s.title as stage_title
    from public.items i
    join public.stages s on s.id = i.stage_id
    where i.workflow_id = p_workflow_id
  )
  select n.id, n.stage_id, n.data, n.created_at, n.job_number
  from numbered n
  where
    n.stage_title ilike '%' || p_query || '%'
    or n.job_number::text = p_query
    or exists (
      select 1
      from jsonb_each_text(n.data) as kv(key, value)
      where kv.value ilike '%' || p_query || '%'
    )
  order by n.created_at desc;
$$;

grant execute on function public.search_items(uuid, text) to authenticated;
