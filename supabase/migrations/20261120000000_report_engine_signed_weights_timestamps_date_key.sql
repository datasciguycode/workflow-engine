-- Four generic report-engine extensions (2026-11-20), needed by the Rideshare Mileage workflow
-- (plans/uber-mileage-tracker/final-plan.md, Step 1) but kept fully generic -- no per-workflow
-- code, same discipline as 20261115010000:
--   1. Signed derived-field weights: a weight may now be negative (previously > 0 only), so a
--      derived field can subtract components, e.g. miles = end_odometer - start_odometer.
--   2. "hidden": true on a field: it still aggregates and still validates derived-field
--      dependencies, but the client doesn't render a card for it. Needed for start_odometer/
--      end_odometer/start_time/end_time, which exist only to support miles/hours and shouldn't
--      show up as their own report rows.
--   3. "parse": "timestamp" on a BASE field (never a derived one): its item.data value is read as
--      epoch seconds via private.jsonb_epoch instead of private.jsonb_numeric, so a derived field
--      can do timestamp arithmetic (hours online = (end_time - start_time) / 3600, weights
--      +-1/3600). Kept for "Hours online": it's small, isolated, and hours is the denominator of
--      the driver's real productivity number (earnings per hour).
--   4. Top-level "item_date_key": which item.data key decides an item's local calendar day for
--      period bucketing, instead of always created_at. Rideshare Mileage buckets by start_time (a
--      shift's "day" is when it started, not when the chat message happened); Rideshare Expenses
--      buckets by its own date field (a Dec 31 receipt logged Jan 2 must land in the 2026 tax
--      year, not 2027). Absent -> old behaviour exactly (falls back to created_at).
--
-- The derived-field "every component present" rule (item_terms, A.4(a)) is unchanged: a shift
-- missing either odometer reading has no miles value for that shift, same as a missing macro.
--
-- item_date_key reads only live item.data, not cleared-stage snapshots -- safe for both configs
-- that use it: Expenses' "date" lives on its only stage, and Mileage's "start_time" isn't shared
-- between stages, so there's no ambiguity about which stage's value it means. A future config
-- pointing item_date_key at a key shared between stages would read only the current stage's live
-- value, same as any other base field.
--
-- Like 20261115010000, replacing report_fields_valid with create or replace does not re-validate
-- existing report_config rows -- only drop/re-add of the CHECK constraint (1d) does that, which is
-- why item_date_key's shape is enforced there instead.
--
-- No existing config (Nutrition Tracker's) uses any of these four features, so report_series must
-- return byte-identical output for it before and after this migration (verified in Step 4).

-- 1a. Signed weights, plus hidden/parse validation. create or replace with the same signature, so
-- the CHECK constraint's dependency on this function survives. Body is identical to
-- 20261115010000's version except the three marked blocks.
create or replace function private.report_fields_valid(p_fields jsonb)
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
               -- NEW: hidden, if present, is a JSON boolean
               when f ? 'hidden' and jsonb_typeof(f -> 'hidden') <> 'boolean' then false
               -- NEW: parse, if present, is "timestamp" and only on a base field
               when f ? 'parse' and (f ? 'weights' or coalesce(f ->> 'parse', '') <> 'timestamp') then false
               when f ? 'weights' then
                 not (f ? 'item_agg')
                 and case when jsonb_typeof(f -> 'weights') = 'object' then
                       coalesce((
                         select bool_and(coalesce(
                           case when jsonb_typeof(w.value) <> 'number' then false
                                when (w.value #>> '{}')::numeric = 0 then false   -- CHANGED: was <= 0
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

-- 1b. private.jsonb_epoch: a base field with "parse": "timestamp" reads its value as epoch
-- seconds, so a derived field can subtract two timestamps (Rideshare hours online = end_time -
-- start_time, weights +-1/3600). Only ISO 8601 with an explicit offset/Z is accepted, so the
-- result never depends on the session TimeZone. Unparseable -> null -> ignored, same contract as
-- jsonb_numeric. plpgsql for the exception handler (a regex can't rule out month 13; one bad
-- value must not abort the whole report). STABLE, not IMMUTABLE: the text->timestamptz cast is
-- STABLE.
create function private.jsonb_epoch(v jsonb)
returns numeric
language plpgsql
stable
set search_path = ''
as $$
begin
  if jsonb_typeof(v) = 'string'
     and (v #>> '{}') ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}(:?\d{2})?)$' then
    return extract(epoch from (v #>> '{}')::timestamptz);
  end if;
  return null;
exception when others then
  return null;
end;
$$;
revoke all on function private.jsonb_epoch(jsonb) from public;
grant execute on function private.jsonb_epoch(jsonb) to authenticated;

-- 1c. private.item_local_date: which local calendar day an item belongs to, when item_date_key is
-- configured and the item has a value for it. A plain "YYYY-MM-DD" is taken as-is (a receipt date
-- is a calendar date, not an instant). An ISO timestamp with offset is converted to p_tz's local
-- date (a shift's start_time). Anything else -> null, and the caller falls back to created_at.
-- Never raises.
create function private.item_local_date(v jsonb, p_tz text)
returns date
language plpgsql
stable
set search_path = ''
as $$
declare s text;
begin
  if jsonb_typeof(v) <> 'string' then return null; end if;
  s := v #>> '{}';
  if s ~ '^\d{4}-\d{2}-\d{2}$' then return s::date; end if;
  if s ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}(:?\d{2})?)$' then
    return (s::timestamptz at time zone p_tz)::date;
  end if;
  return null;
exception when others then
  return null;
end;
$$;
revoke all on function private.item_local_date(jsonb, text) from public;
grant execute on function private.item_local_date(jsonb, text) to authenticated;

-- 1d. The CHECK gets item_date_key: absent, or a non-empty string. Drop and re-add so existing
-- rows are re-validated (create or replace on the functions above does not re-check them).
alter table public.workflows drop constraint workflows_report_config_shape;
alter table public.workflows add constraint workflows_report_config_shape check (
  report_config is null or (
    jsonb_typeof(report_config) = 'object'
    and coalesce(report_config ->> 'period', '') in ('day', 'week', 'month')
    and private.report_fields_valid(report_config -> 'fields')
    and private.report_item_requires_valid(report_config -> 'item_requires', report_config -> 'fields')
    -- NEW: absent, or a non-empty string.
    and (not (report_config ? 'item_date_key')
         or (jsonb_typeof(report_config -> 'item_date_key') = 'string'
             and (report_config ->> 'item_date_key') <> ''))
  )
);

-- note is deliberately not validated, the same as item_noun. The client ignores a non-string note.

-- 1e. report_series. create or replace with the same signature and return type, still
-- language sql stable security invoker. Three CTEs change (base_fields, its, raw_segments); every
-- other CTE is copied verbatim from 20261115010000.
create or replace function public.report_series(p_workflow_id uuid, p_from date, p_to date, p_tz text default 'UTC')
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
    select f ->> 'key' as key, f ->> 'item_agg' as item_agg, f ->> 'period_agg' as period_agg,
           f ->> 'parse' as parse                                                    -- NEW
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
    -- CHANGED: the item's local day is its item_date_key value if configured and parseable, else
    -- created_at's local day (exactly the old behaviour when item_date_key is absent).
    select i.id, i.stage_id, i.data, i.created_at,
      case cfg.c ->> 'period'
        when 'day'   then d.local_date
        when 'week'  then date_trunc('week',  d.local_date::timestamp)::date
        when 'month' then date_trunc('month', d.local_date::timestamp)::date
      end as period_start
    from public.items i
    cross join cfg
    cross join lateral (
      select coalesce(private.item_local_date(i.data -> (cfg.c ->> 'item_date_key'), p_tz),
                      (i.created_at at time zone p_tz)::date) as local_date
    ) d
    where i.workflow_id = p_workflow_id
      and d.local_date between p_from and p_to
  ),
  raw_segments as (
    -- live value: attributed to the item's current stage, ranks after every snapshot
    select its.id as item_id, its.stage_id, f.key,
           case when f.parse = 'timestamp' then private.jsonb_epoch(its.data -> f.key)    -- CHANGED
                else private.jsonb_numeric(its.data -> f.key) end as v,
           9223372036854775807::bigint as seq
    from its cross join base_fields f
    where its.data ? f.key
    union all
    -- cleared snapshots: attributed to the stage the item was leaving
    select e.item_id, e.from_stage_id, f.key,
           case when f.parse = 'timestamp' then private.jsonb_epoch(e.data -> 'cleared' -> f.key)  -- CHANGED
                else private.jsonb_numeric(e.data -> 'cleared' -> f.key) end,
           e.seq
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
