-- Rideshare Mileage/Expenses report write-path checks against dev (plans/uber-mileage-tracker/
-- final-plan.md, Step 3). Runs after Step 4's push, because it needs the real Rideshare
-- workflows and the engine extensions from 20261120000000.
-- ALWAYS ends in an exception so every write below is rolled back; success is an error message
-- beginning 'PASS'. Safe to re-run.
-- All test items are back-dated into the week of 2026-01-05 (America/Chicago), which predates
-- any real rideshare activity, so real items never mix into the asserted numbers.
do $$
declare
  v_mi  uuid; v_ex uuid; v_uid uuid;
  d_a uuid; d_b uuid; d_x uuid; d_y uuid; d_z uuid;
  v_fv jsonb; v_rows int;
begin
  ---------------------------------------------------------------- setup (as the CLI's role)
  select id into v_mi from public.workflows where name = 'Rideshare Mileage';
  select id into v_ex from public.workflows where name = 'Rideshare Expenses';
  if v_mi is null or v_ex is null then
    raise exception 'SETUP: Rideshare Mileage/Expenses workflow not found (Step 4 push not applied?)';
  end if;
  select am.user_id into v_uid
  from public.account_members am
  join public.workflows w on w.account_id = am.account_id
  where w.id = v_mi and am.role = 'owner'
  order by am.created_at
  limit 1;
  if v_uid is null then raise exception 'SETUP: owner not found'; end if;
  if exists (select 1 from public.items where workflow_id in (v_mi, v_ex) and created_at < '2026-03-01') then
    raise exception 'SETUP: real rideshare items exist before 2026-03-01; test week is not isolated';
  end if;

  ---------------------------------------------------------------- become the real user; exercise the grants on jsonb_epoch/item_local_date
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;

  ---------------------------------------------------------------- 1. two shifts in the same week
  select id into d_a from public.create_item(v_mi, jsonb_build_object(
    'start_odometer', 48000, 'end_odometer', 48123,
    'start_time', '2026-01-05T14:00:00Z', 'end_time', '2026-01-05T22:30:00Z'));
  select id into d_b from public.create_item(v_mi, jsonb_build_object(
    'start_odometer', 48200, 'end_odometer', 48290,
    'start_time', '2026-01-07T05:30:00Z', 'end_time', '2026-01-07T09:30:00Z'));

  -- query the full week: item_date_key buckets by start_time's local date (Jan 5 and Jan 6
  -- respectively for shifts A and B), not by created_at, so a single-day query would miss B.
  select field_values into v_fv from public.report_series(v_mi, '2026-01-05', '2026-01-11', 'America/Chicago');
  if (v_fv ->> 'miles')::numeric is distinct from 213 then
    raise exception 'FAIL case1 miles: % (want 213)', v_fv;
  end if;
  if abs((v_fv ->> 'hours')::numeric - 12.5) >= 1e-6 then
    raise exception 'FAIL case1 hours: % (want ~12.5 [8.5 + 4])', v_fv;
  end if;

  ---------------------------------------------------------------- 2. an in-progress shift (start only)
  select item_count into v_rows from public.report_series(v_mi, '2026-01-05', '2026-01-11', 'America/Chicago');
  perform public.create_item(v_mi, jsonb_build_object(
    'start_odometer', 48300, 'start_time', '2026-01-06T14:00:00Z'));
  select field_values into v_fv from public.report_series(v_mi, '2026-01-05', '2026-01-11', 'America/Chicago');
  if (select item_count from public.report_series(v_mi, '2026-01-05', '2026-01-11', 'America/Chicago')) is distinct from v_rows + 1 then
    raise exception 'FAIL case2: item_count did not rise by 1';
  end if;
  if (v_fv ->> 'miles')::numeric is distinct from 213 or abs((v_fv ->> 'hours')::numeric - 12.5) >= 1e-6 then
    raise exception 'FAIL case2: miles/hours changed by the in-progress shift: %', v_fv;
  end if;

  ---------------------------------------------------------------- 3. malformed end_time
  perform public.create_item(v_mi, jsonb_build_object(
    'start_odometer', 48400, 'end_odometer', 48450,
    'start_time', '2026-01-08T14:00:00Z', 'end_time', 'yesterday'));
  perform public.create_item(v_mi, jsonb_build_object(
    'start_odometer', 48500, 'end_odometer', 48550,
    'start_time', '2026-01-09T14:00:00Z', 'end_time', '2026-13-01T00:00:00Z'));
  select field_values into v_fv from public.report_series(v_mi, '2026-01-05', '2026-01-11', 'America/Chicago');
  if abs((v_fv ->> 'hours')::numeric - 12.5) >= 1e-6 then
    raise exception 'FAIL case3: malformed end_time contributed hours: %', v_fv;
  end if;
  if private.jsonb_epoch('"2026-13-01T00:00:00Z"') is not null then
    raise exception 'FAIL case3: jsonb_epoch accepted an invalid month';
  end if;
  if private.jsonb_epoch('"2026-01-05T14:00:00"') is not null then
    raise exception 'FAIL case3: jsonb_epoch accepted a timestamp with no offset';
  end if;

  ---------------------------------------------------------------- 4. expense date bucketing
  select id into d_x from public.create_item(v_ex, jsonb_build_object('date', '2025-12-31', 'gas_usd', 40));
  select id into d_y from public.create_item(v_ex, jsonb_build_object('date', 'Dec 31', 'phone_usd', 10));
  select id into d_z from public.create_item(v_ex, '{}'::jsonb);

  reset role;   -- back-dating needs the CLI role; RLS/grant paths are exercised by everything else
  update public.items set created_at = '2026-01-02 15:00-06' where id in (d_x, d_y);
  update public.items set created_at = '2026-01-02 15:00-06' where id = d_z;
  set local role authenticated;

  select field_values into v_fv from public.report_series(v_ex, '2025-12-01', '2025-12-31', 'America/Chicago');
  if (v_fv ->> 'gas_usd')::numeric is distinct from 40 then
    raise exception 'FAIL case4: expense X (date 2025-12-31) should bucket into December: %', v_fv;
  end if;
  select field_values into v_fv from public.report_series(v_ex, '2026-01-01', '2026-01-31', 'America/Chicago');
  if (v_fv ->> 'phone_usd')::numeric is distinct from 10 then
    raise exception 'FAIL case4: expense Y (unparseable date "Dec 31") should fall back to created_at (January): %', v_fv;
  end if;
  if (select item_count from public.report_series(v_ex, '2026-01-01', '2026-01-31', 'America/Chicago')) < 2 then
    raise exception 'FAIL case4: expense Z (no date) should also fall back to January';
  end if;

  raise exception 'PASS (all rolled back): two-shift week miles 213 / hours ~12.5 ok, in-progress shift ignored, malformed end_time contributes no hours and raises no error, jsonb_epoch rejects bad month and missing offset, expense date bucketing (explicit date / unparseable fallback / absent fallback) ok';
end;
$$;
