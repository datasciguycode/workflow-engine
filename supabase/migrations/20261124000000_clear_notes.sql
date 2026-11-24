-- Lets "Clear All" (added earlier today for checklist fields) also clear a stage's logged notes
-- (2026-11-24 user request: "Think clear all should include clearing the notes as well").
--
-- item_events is append-only at the database level by design (no UPDATE/DELETE policy, ever --
-- see 20261012035437) so existing item.note_added rows are never actually removed. Instead this
-- adds a new event_type, item.notes_cleared, stamped with the stage being cleared -- the UI then
-- hides any note for that stage created at or before the latest clear marker, the same "replay
-- the log, don't mutate it" approach item.stage_changed's own "cleared" snapshot already uses.

alter table public.item_events drop constraint item_events_event_type_check;
alter table public.item_events add constraint item_events_event_type_check
  check (event_type in (
    'item.created', 'item.stage_changed', 'item.data_changed', 'item.note_added',
    'item.notes_cleared'
  ));

create function public.clear_notes(p_item_id uuid, p_stage_id uuid)
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

  insert into public.item_events (item_id, event_type, stage_id)
  values (p_item_id, 'item.notes_cleared', p_stage_id)
  returning * into v_event;

  return v_event;
end;
$$;

revoke all on function public.clear_notes(uuid, uuid) from public;
grant execute on function public.clear_notes(uuid, uuid) to authenticated;
