-- Phase 4b: item_events.stage_id -- which stage the job was at when the event happened.
-- move_stage already recorded from_stage_id/to_stage_id, but create_item, update_data, and
-- add_note events carried no stage at all, so there was no way to filter a job's history down
-- to "what happened while it sat at stage X" (needed for the UI's job -> stage -> log drill-down).
-- stage_id is the event's own home stage: for stage_changed, that's the stage moved INTO
-- (to_stage_id) -- the event belongs to the stage the job arrived at, not the one it left.

alter table public.item_events
  add column stage_id uuid references public.stages (id);

create or replace function public.create_item(p_workflow_id uuid, p_stage_id uuid, p_data jsonb default '{}')
returns public.items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item public.items;
begin
  insert into public.items (workflow_id, stage_id, data)
  values (p_workflow_id, p_stage_id, coalesce(p_data, '{}'::jsonb))
  returning * into v_item;

  insert into public.item_events (item_id, event_type, stage_id)
  values (v_item.id, 'item.created', p_stage_id);

  return v_item;
end;
$$;

create or replace function public.move_stage(p_item_id uuid, p_to_stage_id uuid)
returns public.items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item public.items;
  v_from_stage uuid;
begin
  select * into v_item from public.items where id = p_item_id for update;
  if not found then
    raise exception 'item not found';
  end if;

  v_from_stage := v_item.stage_id;

  update public.items
  set stage_id = p_to_stage_id, updated_at = now()
  where id = p_item_id
  returning * into v_item;

  insert into public.item_events (item_id, event_type, from_stage_id, to_stage_id, stage_id)
  values (p_item_id, 'item.stage_changed', v_from_stage, p_to_stage_id, p_to_stage_id);

  return v_item;
end;
$$;

create or replace function public.update_data(p_item_id uuid, p_patch jsonb)
returns public.items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item public.items;
  v_delete_keys text[];
begin
  select * into v_item from public.items where id = p_item_id for update;
  if not found then
    raise exception 'item not found';
  end if;

  select array_agg(key) into v_delete_keys
  from jsonb_each(p_patch)
  where value = 'null'::jsonb;

  update public.items
  set data = (data || p_patch) - coalesce(v_delete_keys, array[]::text[]),
      updated_at = now()
  where id = p_item_id
  returning * into v_item;

  insert into public.item_events (item_id, event_type, data, stage_id)
  values (p_item_id, 'item.data_changed', p_patch, v_item.stage_id);

  return v_item;
end;
$$;

create or replace function public.add_note(p_item_id uuid, p_note text)
returns public.item_events
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item public.items;
  v_event public.item_events;
begin
  select * into v_item from public.items where id = p_item_id;
  if not found then
    raise exception 'item not found';
  end if;

  insert into public.item_events (item_id, event_type, data, stage_id)
  values (p_item_id, 'item.note_added', to_jsonb(p_note), v_item.stage_id)
  returning * into v_event;

  return v_event;
end;
$$;
