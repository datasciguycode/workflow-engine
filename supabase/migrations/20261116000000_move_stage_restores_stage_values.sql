-- move_stage: every move between two sequenced stages saves the departing stage's shared-field
-- values and restores the arriving stage's own (2026-11-16). Fixes the residual limitation
-- 20261115000000 left (plans/move-stage-backward-snapshot/): a backward move used to clear and
-- record nothing, so item.data kept the later stage's values while the item sat at the earlier
-- stage -- shown under the earlier stage's name, added to by Scan Plate as if they were that
-- stage's, and, on the next forward move, snapshotted as that stage's value, silently replacing
-- its real snapshot (report_series then reported the later stage's numbers for it).
-- Invariant after this migration: for every key two sequenced stages share, item.data holds the
-- CURRENT stage's value or nothing. Three changes, all inside the shared-key path, so a workflow
-- whose stages share no keys (the mechanic, Feature Pipeline) behaves exactly as before:
--   1. Shared keys are computed for any move between two different sequence_order values, not only
--      forward ones. Moves involving an unsequenced stage (null sequence_order, e.g. the mechanic's
--      "closed") or between equal sequence_orders still touch nothing, as before.
--   2. The snapshot lists EVERY shared key, an absent one as JSON null ("this stage had no value"),
--      not only the keys present. Without that, a value deleted at a stage (update_data with null)
--      could be restored from an older snapshot. report_series (20261115010000) needs no change: a
--      JSON-null snapshot is a segment whose value is null, which it already ignores in sums/avgs
--      and which correctly wins its stage's dedupe over an older non-null snapshot.
--   3. After clearing, each shared key is restored from the arriving stage's latest snapshot that
--      lists it (latest per key by item_events.seq: the same per-(item, from_stage, key) rule
--      report_series uses, so what the stage shows and what the report counts for it agree).
--      A JSON-null or missing snapshot restores nothing. A stage never visited restores nothing,
--      so a first-time forward move behaves exactly as before.
-- No backfill: as of 2026-11-16 dev had never recorded a backward move or a cleared snapshot, so
-- nothing was misattributed. Snapshots written before this migration (presence-only format) are
-- still read correctly: a key they don't list just isn't restored.
-- Note for report_series (20261115010000), item_agg "last": it ranks a stage's values by
-- item_events.seq with the live value newest. Now that a backward move restores the arriving
-- stage's own value, an item parked back at an earlier stage reports THAT stage's value as "last"
-- for a shared checklist key -- i.e. whichever stage the item currently sits at, not the most
-- recently entered value. No shipped config uses "last" on a shared key; if one ever does, it
-- probably wants to order by stages.sequence_order instead.
-- item_events is now read on the WRITE path: item.data after a move depends on earlier
-- item.stage_changed snapshots. Never prune/archive those rows' data. The restore query below
-- and report_series's segment ranking implement the same per-(item, from_stage, key) "latest by
-- seq" rule independently; a change to either must be mirrored in the other.
-- Body is otherwise identical to 20261115000000.

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
  v_cleared jsonb;
  v_restored jsonb;  -- NEW
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

  if v_from_seq is not null and v_to_seq is not null and v_to_seq <> v_from_seq then  -- CHANGED: was v_to_seq > v_from_seq
    select array_agg(elem) into v_shared_keys
    from jsonb_array_elements_text(coalesce(v_to_checklist, '[]'::jsonb)) elem
    where coalesce(v_from_checklist, '[]'::jsonb) ? elem;
  end if;

  -- CHANGED: every shared key, an absent one as JSON null (v_item is still the pre-update row).
  -- No shared keys -> zero rows -> jsonb_object_agg returns null -> event data stays null.
  select jsonb_object_agg(k, coalesce(v_item.data -> k, 'null'::jsonb)) into v_cleared
  from unnest(coalesce(v_shared_keys, array[]::text[])) as k;

  -- NEW: the arriving stage's own values, from the last time the item left it. Per key, the
  -- latest snapshot (by seq) out of p_to_stage_id that lists the key; JSON null = no value.
  select jsonb_object_agg(r.k, r.v) into v_restored
  from (
    select distinct on (s.k) s.k, e.data -> 'cleared' -> s.k as v
    from unnest(coalesce(v_shared_keys, array[]::text[])) as s(k)
    join public.item_events e
      on e.item_id = p_item_id
     and e.event_type = 'item.stage_changed'
     and e.from_stage_id = p_to_stage_id
     and e.data -> 'cleared' ? s.k
    order by s.k, e.seq desc
  ) r
  where jsonb_typeof(r.v) <> 'null';

  update public.items
  set stage_id = p_to_stage_id,
      data = (data - coalesce(v_shared_keys, array[]::text[])) || coalesce(v_restored, '{}'::jsonb),  -- CHANGED
      updated_at = now()
  where id = p_item_id
  returning * into v_item;

  insert into public.item_events (item_id, event_type, from_stage_id, to_stage_id, stage_id, data)
  values (p_item_id, 'item.stage_changed', v_from_stage, p_to_stage_id, p_to_stage_id,
          case when v_cleared is not null then jsonb_build_object('cleared', v_cleared) end);

  return v_item;
end;
$$;
