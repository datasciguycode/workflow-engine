-- Phase 1: port the mechanic workflow's happy path (SPEC.md §7).
-- Discovers two workflow-shape fields that Phase 0 deliberately left out:
--   stages.is_initial   -- "which stage does a new item land in?"
--   item_events.seq     -- chronology, once ordering actually matters for the first time.

alter table public.stages
  add column is_initial boolean not null default false;

-- At most one is_initial stage per workflow (SPEC.md §1).
create unique index stages_one_initial_per_workflow
  on public.stages (workflow_id)
  where is_initial;

alter table public.item_events
  add column seq bigserial not null;

create index item_events_item_seq on public.item_events (item_id, seq);

-- create_item's signature changes: it no longer takes a caller-supplied stage_id. It now looks up
-- the workflow's is_initial stage itself and raises if there is none (SPEC.md §2, "Create item").
drop function public.create_item(uuid, uuid, jsonb);

create function public.create_item(p_workflow_id uuid, p_data jsonb default '{}')
returns public.items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_initial_stage uuid;
  v_item public.items;
begin
  select id into v_initial_stage
  from public.stages
  where workflow_id = p_workflow_id and is_initial;

  if v_initial_stage is null then
    raise exception 'workflow % has no is_initial stage', p_workflow_id;
  end if;

  insert into public.items (workflow_id, stage_id, data)
  values (p_workflow_id, v_initial_stage, coalesce(p_data, '{}'::jsonb))
  returning * into v_item;

  insert into public.item_events (item_id, event_type)
  values (v_item.id, 'item.created');

  return v_item;
end;
$$;

revoke all on function public.create_item(uuid, jsonb) from public;
grant execute on function public.create_item(uuid, jsonb) to authenticated;
