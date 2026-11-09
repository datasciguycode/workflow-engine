-- add_note used to always tag a note with the item's own CURRENT stage (v_item.stage_id),
-- inferred server-side -- there was no way to record a job-level note with no stage at all.
-- Caller now decides explicitly: the stage page passes that stage's id, the job overview page
-- passes null, so stage_id IS NULL becomes the signal for "this is a job-level note," distinct
-- from "a note made while sitting at some particular stage." Same item_events table, same column
-- (already nullable) -- just no longer auto-filled from the item's live stage.

drop function if exists public.add_note(uuid, text);

create function public.add_note(p_item_id uuid, p_note text, p_stage_id uuid default null)
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
  values (p_item_id, 'item.note_added', to_jsonb(p_note), p_stage_id)
  returning * into v_event;

  return v_event;
end;
$$;

revoke all on function public.add_note(uuid, text, uuid) from public;
grant execute on function public.add_note(uuid, text, uuid) to authenticated;
