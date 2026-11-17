-- move_stage backward-move checks (20261116000000). ALWAYS ends in an exception so every write
-- below is rolled back; success is an error message beginning 'PASS'. Safe to re-run.
-- The test day is back-dated to Mon 2026-02-02 (America/Chicago), which predates the Nutrition
-- Tracker workflow, so real items never mix into the asserted numbers. It logs all three macros at
-- every stage it reports, so the shipped item_requires never drops it (no config swap needed).
do $$
declare
  v_tz  text := 'America/Chicago';
  v_day date := '2026-02-02';
  v_wf uuid; v_uid uuid;
  v_b uuid; v_br uuid; v_l uuid;
  d uuid;
  v_data jsonb; v_ev jsonb; v_fv jsonb;
  v_mech uuid; v_mid uuid; v_m_init uuid; v_m_next uuid; v_mdata jsonb;
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
  if (select report_config from public.workflows where id = v_wf) is null then
    raise exception 'SETUP: Nutrition Tracker has no report_config';
  end if;
  if exists (select 1 from public.items where workflow_id = v_wf and created_at < '2026-11-01') then
    raise exception 'SETUP: real Nutrition items exist before 2026-11-01; test day is not isolated';
  end if;
  select id into v_b  from public.stages where workflow_id = v_wf and title = 'breakfast';
  select id into v_br from public.stages where workflow_id = v_wf and title = 'brunch';
  select id into v_l  from public.stages where workflow_id = v_wf and title = 'lunch';
  if v_b is null or v_br is null or v_l is null then raise exception 'SETUP: meal stages not found'; end if;

  ---------------------------------------------------------------- become the real user; create the test day
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
  -- "description" is not a checklist key: every item.data assertion below includes it, proving
  -- non-shared keys ride through every move untouched.
  select id into d from public.create_item(v_wf, '{"description": "test day"}'::jsonb);
  reset role;
  update public.items set created_at = '2026-02-02 18:00+00' where id = d;
  set local role authenticated;

  ---------------------------------------------------------------- 1. breakfast, forward, brunch
  perform public.update_data(d, '{"protein_g": 30, "carbs_g": 10, "fat_g": 5}');
  perform public.move_stage(d, v_br);
  select data into v_ev from public.item_events
  where item_id = d and event_type = 'item.stage_changed' order by seq desc limit 1;
  -- containment only here, so that against the PRE-fix function the first failure is the defect
  -- itself (check 2); the full all-keys-with-nulls format is asserted from check 2 on
  if not coalesce(v_ev -> 'cleared' @> '{"protein_g": 30, "carbs_g": 10, "fat_g": 5}'::jsonb, false) then
    raise exception 'FAIL forward snapshot: % (want breakfast 30/10/5)', v_ev;
  end if;
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day"}'::jsonb then
    raise exception 'FAIL first visit: brunch should start empty, got %', v_data;
  end if;
  perform public.update_data(d, '{"protein_g": 20, "carbs_g": 20, "fat_g": 10}');

  ---------------------------------------------------------------- 2. THE DEFECT: back, then forward without editing
  perform public.move_stage(d, v_b);
  select data into v_ev from public.item_events
  where item_id = d and event_type = 'item.stage_changed' order by seq desc limit 1;
  if v_ev is distinct from '{"cleared": {"protein_g": 20, "carbs_g": 20, "fat_g": 10, "fiber_g": null, "sugar_g": null, "weight_lbs": null}}'::jsonb then
    raise exception 'FAIL backward snapshot: % (want brunch''s 20/20/10; null = old behaviour, nothing recorded)', v_ev;
  end if;
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day", "protein_g": 30, "carbs_g": 10, "fat_g": 5}'::jsonb then
    raise exception 'FAIL backward restore: % (want breakfast''s own 30/10/5; 20/20/10 = old behaviour)', v_data;
  end if;
  select field_values into v_fv from public.report_series(v_wf, v_day, v_day, v_tz);
  if v_fv is distinct from '{"protein_g": 50, "carbs_g": 30, "fat_g": 15, "calories": 455}'::jsonb then
    raise exception 'FAIL report while backed up: % (want 50/30/15, 455; 20/20/10, 250 = old behaviour)', v_fv;
  end if;

  perform public.move_stage(d, v_br);
  select data into v_ev from public.item_events
  where item_id = d and event_type = 'item.stage_changed' order by seq desc limit 1;
  if v_ev is distinct from '{"cleared": {"protein_g": 30, "carbs_g": 10, "fat_g": 5, "fiber_g": null, "sugar_g": null, "weight_lbs": null}}'::jsonb then
    raise exception 'FAIL re-departure snapshot: % (want breakfast''s 30/10/5; 20/20/10 = THE DEFECT)', v_ev;
  end if;
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day", "protein_g": 20, "carbs_g": 20, "fat_g": 10}'::jsonb then
    raise exception 'FAIL forward restore: % (want brunch''s 20/20/10 back; empty = old behaviour)', v_data;
  end if;
  select field_values into v_fv from public.report_series(v_wf, v_day, v_day, v_tz);
  if v_fv is distinct from '{"protein_g": 50, "carbs_g": 30, "fat_g": 15, "calories": 455}'::jsonb then
    raise exception 'FAIL report after back-and-forward: % (want 50/30/15, 455; 20/20/10, 250 = THE DEFECT)', v_fv;
  end if;

  ---------------------------------------------------------------- 3. back up and add, Scan Plate style (read live, add, write)
  perform public.move_stage(d, v_b);
  select data into v_data from public.items where id = d;
  perform public.update_data(d, jsonb_build_object('protein_g', (v_data ->> 'protein_g')::numeric + 5));
  perform public.move_stage(d, v_br);
  select field_values into v_fv from public.report_series(v_wf, v_day, v_day, v_tz);
  if v_fv is distinct from '{"protein_g": 55, "carbs_g": 30, "fat_g": 15, "calories": 475}'::jsonb then
    raise exception 'FAIL add while backed up: % (want breakfast 35 + brunch 20 = 55 protein, 475)', v_fv;
  end if;

  ---------------------------------------------------------------- 4. a deleted value is not resurrected
  perform public.update_data(d, '{"fat_g": null}');      -- delete brunch's fat
  perform public.move_stage(d, v_b);
  perform public.move_stage(d, v_br);
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day", "protein_g": 20, "carbs_g": 20}'::jsonb then
    raise exception 'FAIL delete: % (want brunch without fat_g; fat_g 10 = an older snapshot resurrected)', v_data;
  end if;
  select field_values into v_fv from public.report_series(v_wf, v_day, v_day, v_tz);
  if v_fv is distinct from '{"protein_g": 55, "carbs_g": 30, "fat_g": 5, "calories": 385}'::jsonb then
    raise exception 'FAIL delete report: % (want fat 5 = breakfast only; 15 = deleted brunch fat still counted)', v_fv;
  end if;

  ---------------------------------------------------------------- 5. two stages back, then a forward skip
  perform public.move_stage(d, v_l);
  perform public.update_data(d, '{"protein_g": 15, "carbs_g": 5, "fat_g": 5}');
  perform public.move_stage(d, v_b);                     -- lunch -> breakfast
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day", "protein_g": 35, "carbs_g": 10, "fat_g": 5}'::jsonb then
    raise exception 'FAIL two back: % (want breakfast 35/10/5)', v_data;
  end if;
  perform public.move_stage(d, v_l);                     -- breakfast -> lunch (skip)
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day", "protein_g": 15, "carbs_g": 5, "fat_g": 5}'::jsonb then
    raise exception 'FAIL skip restore: % (want lunch 15/5/5)', v_data;
  end if;
  select field_values into v_fv from public.report_series(v_wf, v_day, v_day, v_tz);
  if v_fv is distinct from '{"protein_g": 70, "carbs_g": 35, "fat_g": 10, "calories": 510}'::jsonb then
    raise exception 'FAIL skip report: % (want 35+20+15 / 10+20+5 / 5+0+5, 510)', v_fv;
  end if;

  ---------------------------------------------------------------- 6. same-stage move: nothing cleared or recorded
  perform public.move_stage(d, v_l);
  select data into v_ev from public.item_events
  where item_id = d and event_type = 'item.stage_changed' order by seq desc limit 1;
  select data into v_data from public.items where id = d;
  if v_ev is not null
     or v_data is distinct from '{"description": "test day", "protein_g": 15, "carbs_g": 5, "fat_g": 5}'::jsonb then
    raise exception 'FAIL same-stage: event % data %', v_ev, v_data;
  end if;

  ---------------------------------------------------------------- 7. mechanic (no shared keys): backward move unchanged
  select id into v_mech from public.workflows where name = 'Joe''s Auto Repair';
  select id into v_mid from public.create_item(v_mech, '{"customer": "test"}'::jsonb);
  select stage_id into v_m_init from public.items where id = v_mid;
  select s.id into v_m_next from public.stages s
  where s.workflow_id = v_mech
    and s.sequence_order > (select s0.sequence_order from public.stages s0 where s0.id = v_m_init)
  order by s.sequence_order limit 1;
  perform public.move_stage(v_mid, v_m_next);
  perform public.update_data(v_mid, '{"scheduled_at": "2026-02-03T09:00"}');
  perform public.move_stage(v_mid, v_m_init);
  select data into v_mdata from public.items where id = v_mid;
  if v_mdata is distinct from '{"customer": "test", "scheduled_at": "2026-02-03T09:00"}'::jsonb
     or exists (select 1 from public.item_events where item_id = v_mid
                and event_type = 'item.stage_changed' and data is not null) then
    raise exception 'FAIL mechanic: data % or a stage_changed event has data', v_mdata;
  end if;

  raise exception 'PASS (all rolled back): snapshots list every shared key (absent = null), backward snapshot + restore ok, report 455 while backed up and after back-and-forward (defect = 250), Scan-Plate-style add 55, deleted value not resurrected, two-back + skip ok, same-stage no-op, mechanic unchanged';
end;
$$;
