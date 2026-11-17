-- Report write-path checks against dev. ALWAYS ends in an exception so every write below is
-- rolled back; success is an error message beginning 'PASS'. Safe to re-run.
-- All test items are back-dated into the week of 2026-01-05 (America/Chicago), which predates the
-- Nutrition Tracker workflow, so real items never mix into the asserted numbers.
do $$
declare
  v_tz  text := 'America/Chicago';
  v_wk  date := '2026-01-05';                 -- a Monday; isolated test week
  v_wf  uuid; v_uid uuid;
  v_b uuid; v_br uuid; v_l uuid;
  d_a uuid; d_b uuid; d_c uuid; d_d uuid; d_e uuid; d_f uuid;
  v_ev jsonb; v_fv jsonb; v_fc jsonb; v_n bigint; v_rows int;
  v_cfg jsonb;                                -- the shipped Nutrition config, restored in check 6
  v_mech uuid; v_m_to uuid; v_mid uuid;
  v_fp uuid; v_fp_skip uuid; v_fpid uuid; v_fp_note text := 'no enforce_stage_order workflow visible; relied on Step 4 diff';
  c text; v_rej int := 0;
begin
  ---------------------------------------------------------------- setup (as the CLI's role)
  select id into v_wf from public.workflows where name = 'Nutrition Tracker';
  select am.user_id into v_uid
  from public.account_members am
  join public.workflows w on w.account_id = am.account_id
  where w.id = v_wf and am.role = 'owner'
  order by am.created_at
  limit 1;
  if v_wf is null or v_uid is null then raise exception 'SETUP: workflow or owner not found'; end if;
  if (select enforce_stage_order from public.workflows where id = v_wf) then
    raise exception 'SETUP: Nutrition Tracker has enforce_stage_order = true; skip case below is invalid';
  end if;
  select report_config into v_cfg from public.workflows where id = v_wf;
  if v_cfg is null then
    raise exception 'SETUP: Nutrition Tracker has no report_config (Step 2 content update did not match)';
  end if;
  -- Exact jsonb equality is order-sensitive although item_requires' meaning isn't: if Step 2's
  -- Nutrition config ever reorders this list, update this literal to match (it's a SETUP guard,
  -- not an assertion about behaviour).
  if v_cfg -> 'item_requires' is distinct from '["protein_g", "carbs_g", "fat_g"]'::jsonb then
    raise exception 'SETUP: Nutrition report_config.item_requires is %, want protein/carbs/fat', v_cfg -> 'item_requires';
  end if;
  if exists (select 1 from public.items where workflow_id = v_wf and created_at < '2026-11-01') then
    raise exception 'SETUP: real Nutrition items exist before 2026-11-01; test week is not isolated';
  end if;
  select id into v_b  from public.stages where workflow_id = v_wf and title = 'breakfast';
  select id into v_br from public.stages where workflow_id = v_wf and title = 'brunch';
  select id into v_l  from public.stages where workflow_id = v_wf and title = 'lunch';

  ---------------------------------------------------------------- 0. jsonb_numeric
  if private.jsonb_numeric('"$1,250.00"') is distinct from 1250
     or private.jsonb_numeric('"30"') is distinct from 30
     or private.jsonb_numeric('42.5') is distinct from 42.5
     or private.jsonb_numeric('"30g"') is not null
     or private.jsonb_numeric('""') is not null
     or private.jsonb_numeric('true') is not null then
    raise exception 'FAIL jsonb_numeric';
  end if;

  ---------------------------------------------------------------- 1. CHECK constraint (as CLI role)
  foreach c in array array[
    '{"period": "week"}',
    '{"fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}]}',
    '{"period": "year", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}]}',
    '[]',
    '{"period": "week", "fields": []}',
    '{"period": "week", "fields": {}}',
    '{"period": "week", "fields": [{"key": "x", "agg": "sum"}]}',
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum"}]}',
    '{"period": "week", "fields": [{"key": "x", "item_agg": "max", "period_agg": "avg"}]}',
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "x", "item_agg": "last", "period_agg": "avg"}]}',
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "period_agg": "avg", "weights": {"y": 4}}]}',
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "period_agg": "avg", "weights": {"x": "4"}}]}',
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "item_agg": "sum", "period_agg": "avg", "weights": {"x": 4}}]}',
    -- JSON-null item_agg
    '{"period": "week", "fields": [{"key": "x", "item_agg": null, "period_agg": "avg"}]}',
    -- JSON-null period_agg
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": null}]}',
    -- numeric key
    '{"period": "week", "fields": [{"key": 5, "item_agg": "sum", "period_agg": "avg"}]}',
    -- empty key
    '{"period": "week", "fields": [{"key": "", "item_agg": "sum", "period_agg": "avg"}]}',
    -- missing key
    '{"period": "week", "fields": [{"item_agg": "sum", "period_agg": "avg"}]}',
    -- missing key beside a keyed field
    '{"period": "week", "fields": [{"key": "a", "item_agg": "sum", "period_agg": "avg"}, {"item_agg": "sum", "period_agg": "avg"}]}',
    -- scalar element
    '{"period": "week", "fields": [5]}',
    -- derived-of-derived component
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "period_agg": "avg", "weights": {"x": 1}}, {"key": "k2", "period_agg": "avg", "weights": {"k": 1}}]}',
    -- empty weights
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "period_agg": "avg", "weights": {}}]}',
    -- array weights
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "period_agg": "avg", "weights": []}]}',
    -- JSON-null weights
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "period_agg": "avg", "weights": null}]}',
    -- zero weight
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "period_agg": "avg", "weights": {"x": 0}}]}',
    -- negative weight
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "period_agg": "avg", "weights": {"x": -4}}]}',
    -- JSON-null fields
    '{"period": "week", "fields": null}',
    -- item_requires: unknown key
    '{"period": "week", "item_requires": ["y"], "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}]}',
    -- item_requires: names a derived field
    '{"period": "week", "item_requires": ["k"], "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "period_agg": "avg", "weights": {"x": 4}}]}',
    -- item_requires: empty array
    '{"period": "week", "item_requires": [], "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}]}',
    -- item_requires: not an array
    '{"period": "week", "item_requires": "x", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}]}',
    -- item_requires: JSON null
    '{"period": "week", "item_requires": null, "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}]}',
    -- item_requires: non-string entry
    '{"period": "week", "item_requires": [5], "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}]}'
  ] loop
    begin
      update public.workflows set report_config = c::jsonb where id = v_wf;
      raise exception 'FAIL check: accepted %', c;
    exception when check_violation then v_rej := v_rej + 1; end;
  end loop;
  if v_rej <> 33 then raise exception 'FAIL check count: % of 33 rejected', v_rej; end if;

  -- Checks 2-5 test D1 (per-stage snapshots) on Mon, which only ever logs protein; under the shipped
  -- item_requires Mon would be dropped from every field. Run them without the gate; check 6
  -- restores the shipped config before asserting the week. (Still the CLI role here.)
  update public.workflows set report_config = v_cfg - 'item_requires' where id = v_wf;

  ---------------------------------------------------------------- become the real user; create the test days
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select id into d_a from public.create_item(v_wf, '{}'::jsonb);   -- Mon: the stage-movement day
  select id into d_b from public.create_item(v_wf, '{"protein_g": 40, "carbs_g": 40, "fat_g": 20, "weight_lbs": 178}'::jsonb);
  select id into d_c from public.create_item(v_wf, '{}'::jsonb);   -- Wed: nothing logged
  select id into d_d from public.create_item(v_wf, '{}'::jsonb);   -- Thu: protein only, as a string
  select id into d_e from public.create_item(v_wf, '{"protein_g": 50, "carbs_g": 80, "fat_g": 20}'::jsonb);
  select id into d_f from public.create_item(v_wf, '{}'::jsonb);   -- Sun 21:00 Chicago = Mon UTC

  reset role;   -- back-dating needs the CLI role; RLS/grant paths are exercised by everything else
  update public.items set created_at = '2026-01-05 18:00+00' where id = d_a;
  update public.items set created_at = '2026-01-06 18:00+00' where id = d_b;
  update public.items set created_at = '2026-01-07 18:00+00' where id = d_c;
  update public.items set created_at = '2026-01-08 18:00+00' where id = d_d;
  update public.items set created_at = '2026-01-09 18:00+00' where id = d_e;
  update public.items set created_at = '2026-01-12 03:00+00' where id = d_f;
  set local role authenticated;

  ---------------------------------------------------------------- 2. snapshot + within-day sum
  perform public.update_data(d_a, '{"protein_g": 30, "weight_lbs": 180}');
  perform public.move_stage(d_a, v_br);
  select data into v_ev from public.item_events
  where item_id = d_a and event_type = 'item.stage_changed' order by seq desc limit 1;
  if v_ev is distinct from '{"cleared": {"protein_g": 30, "weight_lbs": 180}}'::jsonb then
    raise exception 'FAIL snapshot: %', v_ev;
  end if;
  perform public.update_data(d_a, '{"protein_g": 20}');
  select field_values into v_fv from public.report_series(v_wf, v_wk, v_wk, v_tz);
  if (v_fv ->> 'protein_g')::numeric is distinct from 50 then
    raise exception 'FAIL simple: % (want protein 50)', v_fv;
  end if;

  ---------------------------------------------------------------- 3. back up, correct, forward again
  perform public.move_stage(d_a, v_b);
  perform public.update_data(d_a, '{"protein_g": 35}');
  perform public.move_stage(d_a, v_br);
  perform public.update_data(d_a, '{"protein_g": 20}');
  select field_values into v_fv from public.report_series(v_wf, v_wk, v_wk, v_tz);
  if (v_fv ->> 'protein_g')::numeric is distinct from 55 then
    raise exception 'FAIL correction: % (want protein 55 [85 = no dedupe])', v_fv;
  end if;

  ---------------------------------------------------------------- 4. forward skip out of the same stage
  perform public.move_stage(d_a, v_l);
  perform public.move_stage(d_a, v_b);
  perform public.update_data(d_a, '{"protein_g": 40}');
  perform public.move_stage(d_a, v_l);
  select field_values into v_fv from public.report_series(v_wf, v_wk, v_wk, v_tz);
  if (v_fv ->> 'protein_g')::numeric is distinct from 60 then
    raise exception 'FAIL skip: % (want protein 60; to_stage keying gives 75, no dedupe 125)', v_fv;
  end if;

  ---------------------------------------------------------------- 5. later weigh-in (for check 10); string-typed protein
  perform public.update_data(d_a, '{"weight_lbs": 181}');
  perform public.update_data(d_d, '{"protein_g": "25"}');
  -- the string reaches a reported number (item_requires still stripped, so protein-only Thu counts);
  -- calories stays absent: a derived field needs every component (D10 step 1)
  select field_values into v_fv from public.report_series(v_wf, v_wk + 3, v_wk + 3, v_tz);
  if (v_fv ->> 'protein_g')::numeric is distinct from 25
     or (select count(*) from jsonb_object_keys(v_fv)) is distinct from 1 then
    raise exception 'FAIL string: % (want exactly {protein_g: 25})', v_fv;
  end if;

  ---------------------------------------------------------------- 6. the four weekly numbers (A.4: one day-set for all four)
  reset role;   -- restore the shipped config (with item_requires); same reason as check 10
  update public.workflows set report_config = v_cfg where id = v_wf;
  set local role authenticated;
  select item_count, field_values, field_counts into v_n, v_fv, v_fc
  from public.report_series(v_wf, v_wk, v_wk + 6, v_tz);
  if v_n is distinct from 6
     or (select count(*) from jsonb_object_keys(v_fv)) is distinct from 4
     or (v_fv ->> 'protein_g')::numeric is distinct from 45
     or (v_fv ->> 'carbs_g')::numeric   is distinct from 60
     or (v_fv ->> 'fat_g')::numeric     is distinct from 20
     or (v_fv ->> 'calories')::numeric  is distinct from 600
     or (v_fc ->> 'calories')::int  is distinct from 2
     or (v_fc ->> 'protein_g')::int is distinct from 2
     or (v_fc ->> 'carbs_g')::int   is distinct from 2
     or (v_fc ->> 'fat_g')::int     is distinct from 2 then
    raise exception 'FAIL week: count % values % counts % (want 4 keys, all over the same 2 days: protein 45, carbs 60, fat 20, calories 600 [protein 43.75/4 = calories-only filter; calories 385/4 = partial days counted])',
      v_n, v_fv, v_fc;
  end if;
  -- the four numbers agree exactly: calories = 4p + 4c + 9f of the displayed averages
  if (v_fv ->> 'calories')::numeric is distinct from
       4 * (v_fv ->> 'protein_g')::numeric + 4 * (v_fv ->> 'carbs_g')::numeric + 9 * (v_fv ->> 'fat_g')::numeric then
    raise exception 'FAIL consistency: % (calories <> 4p + 4c + 9f)', v_fv;
  end if;
  -- a partial day is dropped from ALL four, not just calories: Mon alone (protein only) is empty
  select field_values, field_counts into v_fv, v_fc from public.report_series(v_wf, v_wk, v_wk, v_tz);
  if v_fv is distinct from '{}'::jsonb or v_fc is distinct from '{}'::jsonb then
    raise exception 'FAIL gate: Mon (protein only) should contribute to no field: % / %', v_fv, v_fc;
  end if;

  ---------------------------------------------------------------- 7. timezone bucketing at the week boundary
  select count(*) into v_rows from public.report_series(v_wf, v_wk, v_wk + 7, 'UTC');
  if v_rows is distinct from 2
     or (select item_count from public.report_series(v_wf, v_wk, v_wk + 7, 'UTC') where period_start = v_wk) is distinct from 5 then
    raise exception 'FAIL tz: UTC should split the Sunday-night item into the next week';
  end if;

  ---------------------------------------------------------------- 8. mechanic: no shared keys -> data null
  select id into v_mech from public.workflows where name = 'Joe''s Auto Repair';
  select id into v_mid from public.create_item(v_mech, '{}'::jsonb);
  select s.id into v_m_to from public.stages s
  where s.workflow_id = v_mech
    and s.sequence_order > (select s0.sequence_order from public.items i
                            join public.stages s0 on s0.id = i.stage_id where i.id = v_mid)
  order by s.sequence_order limit 1;
  perform public.move_stage(v_mid, v_m_to);
  if exists (select 1 from public.item_events where item_id = v_mid
             and event_type = 'item.stage_changed' and data is not null) then
    raise exception 'FAIL mechanic: stage_changed.data not null';
  end if;

  ---------------------------------------------------------------- 9. enforce_stage_order still enforced (if reachable)
  select id into v_fp from public.workflows where enforce_stage_order limit 1;   -- RLS-scoped
  if v_fp is not null then
    select id into v_fpid from public.create_item(v_fp, '{}'::jsonb);
    select s.id into v_fp_skip from public.stages s
    where s.workflow_id = v_fp and s.sequence_order is not null
      and s.sequence_order > (select s0.sequence_order from public.items i
                              join public.stages s0 on s0.id = i.stage_id where i.id = v_fpid) + 1
    order by s.sequence_order limit 1;
    if v_fp_skip is not null then
      begin
        perform public.move_stage(v_fpid, v_fp_skip);
        raise exception 'FAIL enforce: forward skip was allowed';
      exception when others then
        if sqlerrm not like 'forward skip%' then raise; end if;
      end;
      v_fp_note := 'forward skip rejected';
    end if;
  end if;

  ---------------------------------------------------------------- 10. generic engine: 'last' at both levels (throwaway config, rolled back)
  -- Not a Nutrition config: Nutrition no longer uses 'last', but the engine keeps it, so it stays tested.
  reset role;   -- workflows_update RLS; same reason the CHECK probes run as the CLI role
  update public.workflows set report_config = '{"period": "week", "fields": [
      {"key": "weight_lbs", "item_agg": "last", "period_agg": "avg"},
      {"key": "protein_g",  "item_agg": "sum",  "period_agg": "last"}]}'::jsonb
  where id = v_wf;
  set local role authenticated;
  select field_values, field_counts into v_fv, v_fc
  from public.report_series(v_wf, v_wk, v_wk + 6, v_tz);
  if (v_fv ->> 'weight_lbs')::numeric is distinct from 179.5
     or (v_fc ->> 'weight_lbs')::int   is distinct from 2
     or (v_fv ->> 'protein_g')::numeric is distinct from 50 then
    raise exception 'FAIL last: % / % (want weight 179.5 over 2 days [Mon item_agg sum = 361], protein last = Fri 50)',
      v_fv, v_fc;
  end if;

  raise exception 'PASS (all rolled back): jsonb_numeric ok, % bad configs rejected, snapshot ok, within-day 50/55/60, string 25 ok, week four numbers ok (45/60/20, calories 600 = 4p+4c+9f, all over the same 2 complete days), partial day dropped from all four, tz ok, mechanic data null, enforce: %, generic last ok',
    v_rej, v_fp_note;
end;
$$;
