-- Generic per-workflow Report (2026-11-15). First (and only) consumer: Nutrition Tracker's weekly
-- report -- four numbers: average daily calories, protein, carbs and fat. Built generically
-- anyway: like stages.checklist, which fields matter and how is per-workflow jsonb config read by
-- one generic page, not code. jsonb on workflows rather than a child table for the same reason
-- checklist is (20261104020000): static, migration-authored metadata read wholesale. On
-- workflows, not stages, because a report spans stages. null = this workflow has no report (and
-- the UI shows no Report link). No goals, no % split, no chat access: the user explicitly scoped
-- this to the four averages.
--
-- Two aggregation levels per field, both required, no defaults:
--   item_agg   -- combines one item's per-stage values (a Nutrition day: sum its meals)
--   period_agg -- combines a period's item values (a Nutrition week: average the days)
-- One shared "agg" can't say "sum within a day, then average across the week", and a silently
-- defaulted level is how a once-a-day reading ends up summed across meals. sum/avg ignore nulls
-- at both levels.
-- A derived field has "weights" instead of item_agg: per item, sum(weight * component value),
-- only for items that have EVERY component (an item missing one has no value for the derived
-- field) -- chosen by the user 2026-11-15 (plans/generic-report-feature/, D10, "A.4 (a)"): a
-- missing macro is unknown, not 0, the same rule base fields follow. Then period_agg as usual.
-- Calories = 4p + 4c + 9f lives in config, not code, and is never stored: no calories key is ever
-- written to item.data; it is recomputed from the grams on every call.
-- Optional top-level "item_requires" (a list of base keys): an item missing any of them is dropped
-- from EVERY field, so all fields aggregate over one item set. Nutrition lists protein/carbs/fat:
-- a day counts toward all four averages or none (user decision 2026-11-15, A.4, round 6), so the
-- four always agree (avg calories = 4p + 4c + 9f of the averaged macros).
--
-- The CHECK must never evaluate to NULL for a non-null report_config (a CHECK passes on NULL as
-- well as TRUE), so every level of report_fields_valid coalesces to false, and CASE (not AND)
-- guards anything that would error on the wrong jsonb type. Per-field validation needs a
-- subquery, which a CHECK can't contain directly, hence the function. It reads only its argument,
-- so IMMUTABLE is honest. Note: replacing this function later does not re-check existing rows.

create function private.report_fields_valid(p_fields jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when jsonb_typeof(p_fields) = 'array' and jsonb_array_length(p_fields) > 0 then
      coalesce((
        select bool_and(coalesce(
          case when jsonb_typeof(f) <> 'object' then false
               when coalesce(jsonb_typeof(f -> 'key'), '') <> 'string' or (f ->> 'key') = '' then false
               when coalesce(f ->> 'period_agg', '') not in ('sum', 'avg', 'last') then false
               when f ? 'weights' then
                 not (f ? 'item_agg')
                 and case when jsonb_typeof(f -> 'weights') = 'object' then
                       coalesce((
                         select bool_and(coalesce(
                           case when jsonb_typeof(w.value) <> 'number' then false
                                when (w.value #>> '{}')::numeric <= 0 then false
                                else exists (
                                  select 1 from jsonb_array_elements(p_fields) g
                                  where jsonb_typeof(g) = 'object'
                                    and g ->> 'key' = w.key
                                    and not (g ? 'weights'))
                           end, false))
                         from jsonb_each(f -> 'weights') w
                       ), false)
                     else false end
               else coalesce(f ->> 'item_agg', '') in ('sum', 'avg', 'last')
          end, false))
        from jsonb_array_elements(p_fields) f
      ), false)
      and (select count(*) = count(distinct f ->> 'key') from jsonb_array_elements(p_fields) f)
    else false
  end;
$$;
revoke all on function private.report_fields_valid(jsonb) from public;
grant execute on function private.report_fields_valid(jsonb) to authenticated;

-- item_requires: absent (SQL NULL from ->) = no requirement = valid. Present: a non-empty array of
-- strings, each the key of a base (non-derived) field in fields. A JSON null, a non-array, an empty
-- array, a non-string entry or an unknown/derived key is invalid. Same never-NULL discipline as
-- report_fields_valid. The CASE on p_fields' type guards jsonb_array_elements, because the CHECK's
-- AND doesn't guarantee report_fields_valid is evaluated first.
create function private.report_item_requires_valid(p_requires jsonb, p_fields jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p_requires is null then true
    when jsonb_typeof(p_requires) = 'array' and jsonb_array_length(p_requires) > 0 then
      coalesce((
        select bool_and(coalesce(
          case when jsonb_typeof(r) <> 'string' then false
               else exists (
                 select 1
                 from jsonb_array_elements(case when jsonb_typeof(p_fields) = 'array'
                                                then p_fields else '[]'::jsonb end) g
                 where jsonb_typeof(g) = 'object'
                   and g ->> 'key' = r #>> '{}'
                   and not (g ? 'weights'))
          end, false))
        from jsonb_array_elements(p_requires) r
      ), false)
    else false
  end;
$$;
revoke all on function private.report_item_requires_valid(jsonb, jsonb) from public;
grant execute on function private.report_item_requires_valid(jsonb, jsonb) to authenticated;

alter table public.workflows
  add column report_config jsonb
  constraint workflows_report_config_shape check (
    report_config is null or (
      jsonb_typeof(report_config) = 'object'
      and coalesce(report_config ->> 'period', '') in ('day', 'week', 'month')
      and private.report_fields_valid(report_config -> 'fields')
      and private.report_item_requires_valid(report_config -> 'item_requires', report_config -> 'fields')
    )
  );

-- Report values come from free-form item.data. The agent's update_data patch is untyped, so a
-- chat correction can store "30" or "$1,250.00" as a string; that shouldn't silently drop out of
-- a total. Unparseable ("30g", "", true) -> null -> ignored. In private (not exposed as an RPC)
-- like the access helpers; invoker rights, since it touches no tables.
create function private.jsonb_numeric(v jsonb)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case jsonb_typeof(v)
    when 'number' then (v #>> '{}')::numeric
    when 'string' then
      case when regexp_replace(v #>> '{}', '[\s$,]', '', 'g') ~ '^-?\d+(\.\d+)?$'
           then regexp_replace(v #>> '{}', '[\s$,]', '', 'g')::numeric end
  end;
$$;
revoke all on function private.jsonb_numeric(jsonb) from public;
grant execute on function private.jsonb_numeric(jsonb) to authenticated;

-- One row per non-empty period in [p_from, p_to] (dates in p_tz). An item belongs to the period
-- containing its created_at in the caller's timezone (the browser's local day is what the user
-- means by "today": a 21:53 Central entry is not tomorrow's).
-- A base field's per-item value is built per STAGE the item has been at: the value that field held
-- the last time the item was at that stage -- its live data value if it's there now, else what
-- move_stage cleared on the most recent forward move OUT of that stage (20261115000000). Deduping
-- per (item, from_stage, key) to the latest seq stops a back-up-and-correct from being added on top
-- of the original snapshot. Keyed on from_stage_id, not to_stage_id: Nutrition allows forward
-- skips, so two departures from the same stage can land on different stages. The surviving
-- per-stage values are combined with item_agg; derived fields are then computed per item (only
-- for items with every component); items failing item_requires (if set) are dropped from every
-- field; then every field's item values are combined with its period_agg.
-- field_counts = items with a non-null value per field (the denominator of an avg).
-- item_count = every item in the period, including ones item_requires dropped.
-- security invoker: RLS on workflows/items/item_events scopes rows, same as search_items. No
-- range cap, also like search_items.
create function public.report_series(p_workflow_id uuid, p_from date, p_to date, p_tz text default 'UTC')
returns table (period_start date, item_count bigint, field_values jsonb, field_counts jsonb)
language sql
stable
security invoker
set search_path = ''
as $$
  with cfg as (
    select w.report_config as c
    from public.workflows w
    where w.id = p_workflow_id and w.report_config is not null
  ),
  base_fields as (
    select f ->> 'key' as key, f ->> 'item_agg' as item_agg, f ->> 'period_agg' as period_agg
    from cfg, jsonb_array_elements(cfg.c -> 'fields') as f
    where not (f ? 'weights')
  ),
  derived_terms as (
    select f ->> 'key' as key, f ->> 'period_agg' as period_agg,
           w.key as comp, (w.value #>> '{}')::numeric as weight
    from cfg, jsonb_array_elements(cfg.c -> 'fields') as f, jsonb_each(f -> 'weights') as w
    where f ? 'weights'
  ),
  its as (
    select i.id, i.stage_id, i.data, i.created_at,
      case cfg.c ->> 'period'
        when 'day'   then (i.created_at at time zone p_tz)::date
        when 'week'  then date_trunc('week',  i.created_at at time zone p_tz)::date
        when 'month' then date_trunc('month', i.created_at at time zone p_tz)::date
      end as period_start
    from public.items i, cfg
    where i.workflow_id = p_workflow_id
      and (i.created_at at time zone p_tz)::date between p_from and p_to
  ),
  raw_segments as (
    -- live value: attributed to the item's current stage, ranks after every snapshot
    select its.id as item_id, its.stage_id, f.key,
           private.jsonb_numeric(its.data -> f.key) as v,
           9223372036854775807::bigint as seq
    from its cross join base_fields f
    where its.data ? f.key
    union all
    -- cleared snapshots: attributed to the stage the item was leaving
    select e.item_id, e.from_stage_id, f.key,
           private.jsonb_numeric(e.data -> 'cleared' -> f.key), e.seq
    from public.item_events e
    join its on its.id = e.item_id
    cross join base_fields f
    where e.event_type = 'item.stage_changed' and e.data -> 'cleared' ? f.key
  ),
  segments as (
    -- one value per (item, stage, field): the latest
    select distinct on (r.item_id, r.stage_id, r.key) r.item_id, r.stage_id, r.key, r.v, r.seq
    from raw_segments r
    order by r.item_id, r.stage_id, r.key, r.seq desc
  ),
  item_base as (
    -- level 1 (item_agg): an item's per-stage values -> one value per item
    select s.item_id, s.key, f.period_agg,
      case f.item_agg
        when 'sum'  then sum(s.v)
        when 'avg'  then avg(s.v)
        when 'last' then (array_agg(s.v order by s.seq desc) filter (where s.v is not null))[1]
      end as v
    from segments s
    join base_fields f on f.key = s.key
    group by s.item_id, s.key, f.item_agg, f.period_agg
  ),
  item_terms_all as (
    -- derived fields: one weighted term per (item, derived field, component that has a value)
    select ib.item_id, d.key, d.period_agg, d.comp, d.weight * ib.v as e
    from derived_terms d
    join item_base ib on ib.key = d.comp
    where ib.v is not null
  ),
  item_terms as (
    -- A.4 (a): a derived field's item value uses only items that have EVERY component
    select t.* from item_terms_all t
    where (select count(*) from item_terms_all t2 where t2.item_id = t.item_id and t2.key = t.key)
        = (select count(*) from derived_terms d2 where d2.key = t.key)
  ),
  required as (
    -- item_requires (absent = empty): base keys an item must have a non-null value for
    select distinct r #>> '{}' as key
    from cfg, jsonb_array_elements(coalesce(cfg.c -> 'item_requires', '[]'::jsonb)) as r
  ),
  kept as (
    -- items that pass item_requires; with no requirement, every item (0 = 0)
    select its.id as item_id
    from its
    where (select count(*) from item_base ib
           where ib.item_id = its.id and ib.v is not null
             and ib.key in (select rq.key from required rq))
        = (select count(*) from required)
  ),
  item_vals as (
    -- an item that fails item_requires contributes to NO field, base or derived (one item set)
    select ib.item_id, ib.key, ib.period_agg, ib.v
    from item_base ib join kept k on k.item_id = ib.item_id
    union all
    select t.item_id, t.key, t.period_agg, sum(t.e)
    from item_terms t join kept k on k.item_id = t.item_id
    group by t.item_id, t.key, t.period_agg
  ),
  period_vals as (
    -- level 2 (period_agg): a period's item values -> one value per period
    select its.period_start, iv.key,
      case iv.period_agg
        when 'sum'  then sum(iv.v)
        when 'avg'  then avg(iv.v)
        when 'last' then (array_agg(iv.v order by its.created_at desc, its.id desc) filter (where iv.v is not null))[1]
      end as v,
      count(iv.v) as n
    from item_vals iv
    join its on its.id = iv.item_id
    group by its.period_start, iv.key, iv.period_agg
  )
  select p.period_start,
         count(*) as item_count,
         coalesce((select jsonb_object_agg(pv.key, pv.v) from period_vals pv
                   where pv.period_start = p.period_start and pv.v is not null), '{}'::jsonb),
         coalesce((select jsonb_object_agg(pv.key, pv.n) from period_vals pv
                   where pv.period_start = p.period_start and pv.n > 0), '{}'::jsonb)
  from its p
  group by p.period_start
  order by p.period_start;
$$;
revoke all on function public.report_series(uuid, date, date, text) from public;
grant execute on function public.report_series(uuid, date, date, text) to authenticated;

-- Nutrition Tracker's weekly report: the four numbers the user asked for, in this order. Matched
-- by name since ids differ between dev and prod (same pattern as 20261112000000). Within a day:
-- macros sum across meal stages. Across the week: all four average over the SAME days, those
-- with all three macros (item_requires; user decision, round 6), so the four always agree.
-- fiber_g/sugar_g/weight_lbs are still logged on every stage but are deliberately not reported.
update public.workflows
set report_config = '{
  "period": "week",
  "item_noun": "day",
  "item_requires": ["protein_g", "carbs_g", "fat_g"],
  "fields": [
    {"key": "calories",  "label": "Calories", "unit": "kcal", "period_agg": "avg",
     "weights": {"protein_g": 4, "carbs_g": 4, "fat_g": 9}},
    {"key": "protein_g", "label": "Protein",  "unit": "g", "item_agg": "sum", "period_agg": "avg"},
    {"key": "carbs_g",   "label": "Carbs",    "unit": "g", "item_agg": "sum", "period_agg": "avg"},
    {"key": "fat_g",     "label": "Fat",      "unit": "g", "item_agg": "sum", "period_agg": "avg"}
  ]
}'::jsonb
where name = 'Nutrition Tracker' and report_config is null;
