-- move_stage: clear checklist fields the departing and arriving stages share, on a forward
-- move only (2026-11-13). Discovered via a real Nutrition Tracker test: every meal stage
-- (breakfast/brunch/lunch/linner/dinner) deliberately reuses the exact same field names
-- (protein_g, carbs_g, ...), since item.data is one flat jsonb object per item, not split per
-- stage. Moving Breakfast -> Brunch never cleared those fields, so Brunch displayed Breakfast's
-- leftover numbers as if already filled in. The mechanic workflow never hit this because no two
-- of its stages share a field name (see the checklists in 20261012035437 onward) -- clearing on
-- a shared key is a no-op there, confirmed by checking every stage's checklist before writing
-- this. Only a forward move clears anything, so revisiting an earlier stage (backward/sideways,
-- both still allowed regardless of enforce_stage_order) keeps whatever's already there to edit
-- rather than wiping it out just by landing on it again. The cleared values aren't lost --
-- they're already permanently in item_events, tagged with the stage they were recorded at.
--
-- Also restores the enforce_stage_order forward-skip check (SPEC.md §3), which the 2026-10-16
-- item_events.stage_id migration's "create or replace function move_stage" silently dropped by
-- rewriting the whole function body without it -- Feature Pipeline (enforce_stage_order = true)
-- has been unprotected since. Found incidentally while touching this function for the fix above.

create or replace function public.move_stage(p_item_id uuid, p_to_stage_id uuid)
returns public.items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item public.items;
  v_from_stage uuid;
  v_enforce boolean;
  v_from_seq integer;
  v_to_seq integer;
  v_from_checklist jsonb;
  v_to_checklist jsonb;
  v_shared_keys text[];
begin
  select * into v_item from public.items where id = p_item_id for update;
  if not found then
    raise exception 'item not found';
  end if;

  v_from_stage := v_item.stage_id;

  select enforce_stage_order into v_enforce
  from public.workflows where id = v_item.workflow_id;

  select sequence_order, checklist into v_from_seq, v_from_checklist
  from public.stages where id = v_from_stage;
  select sequence_order, checklist into v_to_seq, v_to_checklist
  from public.stages where id = p_to_stage_id;

  if v_enforce then
    if v_from_seq is not null and v_to_seq is not null
       and v_to_seq > v_from_seq
       and v_to_seq != v_from_seq + 1 then
      raise exception 'forward skip from stage % (seq %) to stage % (seq %) is not allowed when enforce_stage_order is true',
        v_from_stage, v_from_seq, p_to_stage_id, v_to_seq;
    end if;
  end if;

  if v_from_seq is not null and v_to_seq is not null and v_to_seq > v_from_seq then
    select array_agg(elem) into v_shared_keys
    from jsonb_array_elements_text(coalesce(v_to_checklist, '[]'::jsonb)) elem
    where coalesce(v_from_checklist, '[]'::jsonb) ? elem;
  end if;

  update public.items
  set stage_id = p_to_stage_id,
      data = data - coalesce(v_shared_keys, array[]::text[]),
      updated_at = now()
  where id = p_item_id
  returning * into v_item;

  insert into public.item_events (item_id, event_type, from_stage_id, to_stage_id, stage_id)
  values (p_item_id, 'item.stage_changed', v_from_stage, p_to_stage_id, p_to_stage_id);

  return v_item;
end;
$$;
