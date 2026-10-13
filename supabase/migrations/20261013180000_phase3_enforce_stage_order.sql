-- Phase 3: build the SDLC workflow on the now-settled schema (SPEC.md §7).
-- Discovers workflows.enforce_stage_order -- the mechanic workflow never needed hard ordering,
-- so this is added here, for the first time, rather than asserted up front (SPEC.md §0).
--
-- Validation algorithm (SPEC.md §3): strict lockstep forward, open backward, with a
-- null-on-either-side exemption. Runs inside move_stage on every call, for the item's workflow.

alter table public.workflows
  add column enforce_stage_order boolean not null default false;

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
begin
  select * into v_item from public.items where id = p_item_id for update;
  if not found then
    raise exception 'item not found';
  end if;

  v_from_stage := v_item.stage_id;

  select enforce_stage_order into v_enforce
  from public.workflows where id = v_item.workflow_id;

  if v_enforce then
    select sequence_order into v_from_seq from public.stages where id = v_from_stage;
    select sequence_order into v_to_seq from public.stages where id = p_to_stage_id;

    -- null sequence_order on either endpoint always exempts the move (SPEC.md §3); backward or
    -- sideways moves are always allowed regardless of the flag; only a forward move is checked,
    -- and it must be to exactly current + 1 (strict lockstep, no forward skipping).
    if v_from_seq is not null and v_to_seq is not null
       and v_to_seq > v_from_seq
       and v_to_seq != v_from_seq + 1 then
      raise exception 'forward skip from stage % (seq %) to stage % (seq %) is not allowed when enforce_stage_order is true',
        v_from_stage, v_from_seq, p_to_stage_id, v_to_seq;
    end if;
  end if;

  update public.items
  set stage_id = p_to_stage_id, updated_at = now()
  where id = p_item_id
  returning * into v_item;

  insert into public.item_events (item_id, event_type, from_stage_id, to_stage_id)
  values (p_item_id, 'item.stage_changed', v_from_stage, p_to_stage_id);

  return v_item;
end;
$$;
