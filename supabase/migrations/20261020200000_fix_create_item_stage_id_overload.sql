-- 20261016130000_phase4b_item_events_stage_id.sql added stage_id (and kept data) logging on
-- create_item's item.created event, but only on the old 3-arg create_item(workflow_id, stage_id,
-- data) overload. Phase1 (20261012154028) had already replaced that with a 2-arg
-- create_item(workflow_id, data) that looks up is_initial itself -- the one the app and
-- agent-loop actually call -- and that overload never got the stage_id fix, so every
-- item.created event has stage_id null. Caught 2026-10-20: a job's Intake-stage log showed
-- "Nothing logged at this stage yet." because its item.created event didn't belong to any stage.

create or replace function public.create_item(p_workflow_id uuid, p_data jsonb default '{}')
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

  insert into public.item_events (item_id, event_type, stage_id, data)
  values (v_item.id, 'item.created', v_initial_stage, v_item.data);

  return v_item;
end;
$$;
