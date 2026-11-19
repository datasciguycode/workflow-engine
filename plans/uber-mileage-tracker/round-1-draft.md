# Rideshare mileage + expense tracking: round-1 draft plan

Status: draft for review. Dev only (`workflow-engine-test`, ref `utwyvtbzesswpoihmlic`). Nothing in
this plan touches `/home/mmcbride/micah/claude/workflow-app-prod`. Nothing has been executed yet.

Not tax advice. The tax points below are my reading of IRS Pub 463 ch. 5 / Treas. Reg. §1.274-5T
plus secondary sources. They're here so the data model collects the right things. They don't
replace a tax professional.

---

## 0. TL;DR: what changed from the discussed design, and why

The discussed design had two parts. The **Ride** part was per-ride Start/End odometer photo,
location and time, plus derived miles, downtime and area productivity. The **Expenses** part was a
single-stage log with category, amount and date. After checking it against the codebase and the tax
rules, five changes are load-bearing. Each one is argued in its own section.

1. **The unit of tracking becomes a *shift* (app on → app off), not a single ride.** This is the
   biggest change. Section 2 has the reasons:
   - Per-ride odometer spans miss the deductible miles driven while waiting and while heading to a
     pickup. That is often 30–50% of a driver's business miles.
   - Odometers resolve to 1 mile. On a 3-mile ride that's ±33% error.
   - Stacked or queued trips double-count miles.
   - Two dashboard photos per ride, with a passenger in the car, isn't practical or safe.

   The stages, fields and capture UI are identical either way. If the user still wants per-ride,
   the change is just the item label and the report wording.
2. **The report engine can't express most of the requested report config as it stands.** The
   blockers in `report_series` / `report_fields_valid` today:
   - Derived weights must be > 0, so `end - start` is impossible.
   - There is no way to hide the raw odometer inputs.
   - Timestamps aren't numbers.
   - No cross-item computation (needed for downtime).
   - No group-by (needed for per-category and per-area figures).
   - No ratio-of-sums (needed for earnings per hour).
   - Items always bucket by `created_at`, never by a data date.

   This plan adds **four small, generic engine extensions**:
   - signed weights
   - `hidden` fields
   - `parse: "timestamp"` base fields
   - a top-level `item_date_key`

   That covers miles, hours, tolls, parking and earnings. **Downtime, earnings-per-hour and the
   per-area breakdown are deferred to a Phase 2.** Each needs a materially bigger engine feature
   (cross-item window, ratio, group-by), and downtime stops meaning anything once the unit is a
   shift (Section 6).
3. **Expense "category" becomes one amount key per category** (`gas_usd`, `phone_usd`, ...) instead
   of a `category` + `amount` pair. The engine has no group-by, and per-category keys work with the
   existing sum cards unchanged. The category list is also reshaped around a tax fact the original
   design missed. With the standard mileage rate, gas, maintenance and insurance are **not**
   deductible on top of mileage; they're only relevant under the actual-expense method.
4. **Raw GPS coordinates are never stored.** They're rounded to about 110 m in the browser and
   reverse-geocoded to a neighbourhood/city label by a tiny new `reverse-geocode` edge function.
   Only the label is written (Section 5).
5. **The odometer scan always has a manual path.** There's a "type the reading" input next to the
   scan button and a "correct reading" input after a capture, plus plausibility checks against the
   start reading and the previous shift. Every write is already audited by `item_events` (Section 4).

---

## 1. Codebase facts this plan relies on (verified by reading the code)

- **Report engine:** `20261115010000_add_workflow_report_config.sql`.
  - `report_fields_valid` rejects any weight `<= 0`.
  - A derived field's weights must name base fields in `fields`.
  - A derived field has a per-item value only when **every** component is non-null.
  - `report_series` buckets by `items.created_at` in `p_tz` and parses values with
    `private.jsonb_numeric`, which handles numbers and numeric strings only.
  - `period` is one of `day|week|month`, one per workflow.
  - The CHECK says "replacing this function later does not re-check existing rows".
- **`scripts/report_series_dev_check.sql` line ~97** asserts that a **negative weight is rejected**.
  Signed weights break that assertion, so the script must be updated in the same change.
- **`WorkflowReport.razor`** renders one card per field with no skip logic. `ReportField` /
  `ParseReportConfig` live in `web/Services/WorkflowApiClient.cs`. A `$` unit already gets special
  number formatting, and `"unit_position": "prefix"` is already parsed.
- **`move_stage`** clears and restores only keys shared between the departing and arriving stage
  checklists. Shift's `start_*` and `end_*` keys aren't shared, so they all stay live in `item.data`
  through the move and need no snapshot logic.
- **`update_data`** is a top-level merge, where `null` deletes a key. Every call writes an
  `item.data_changed` event with the patch, actor and time. That gives a free audit trail for odometer
  corrections, which matters for substantiation.
- **`WorkflowDetail.razor`:**
  - Scan buttons are gated on the current stage's checklist containing a key (`vin`, `protein_g`),
    and only when viewing the item's actual current stage.
  - `VisibleItems()` hides any item in an `IsTerminal` stage unless "Show closed" is on.
    - **A single-stage (initial+terminal) Expenses workflow would show an empty list by default.**
    - **An in-progress shift would vanish from the list the moment it moves to End.** Both must be
      fixed (Step 6c).
  - For non-job workflows, the item display name is `"{StageTitle} {created_at local yyyy-MM-dd}"`.
    Several expenses on one day would all read "Logged 2026-11-19" (Step 6d).
  - "+ New Item" for non-job workflows creates the item immediately and drills into its stage
    (`StartNewJob`).
  - `FieldText` formats any key containing `time`/`date`/ending `_at` as a date. `start_time` and
    `end_time` therefore display nicely.
  - `FieldUnitSuffixes` only knows `_g` and `_lbs`, as a suffix.
- **Edge functions:** `scan-vin` and `scan-plate` are single-file Deno functions using
  `npm:@anthropic-ai/sdk@0.32.1` and `MODEL = "claude-sonnet-5-5"`. They share the same CORS and
  bearer checks. The photo is never stored. `scan-plate` returns 422 for "judged unreliable".
  `config.toml` has an explicit `[functions.scan-plate] verify_jwt = true` (with the reason why).
- **Deploy conventions:**
  - Functions: `supabase functions deploy <name> --project-ref utwyvtbzesswpoihmlic --use-api`.
    Always name the function, because a bare deploy also pushes `mcp-server`.
  - Migrations: `supabase db push --linked --dry-run`, then `supabase db push --linked`.
  - Web: push to `main` triggers `.github/workflows/deploy-pages.yml`.
  - Content migrations match by **name/title, never id**. Nutrition matched its account via
    `'Joe''s Auto Repair'`.
- **`workflows.name` has no unique constraint.** The Nutrition migration's `on conflict do nothing`
  on `workflows` therefore guards nothing. This plan uses `where not exists` instead.
- **There is an untracked migration `20261119000000_add_closed_at_field.sql`** in the working tree.
  This plan's migrations are timestamped after it (`20261120...`). A `db push` would push it too,
  so see the precondition in Step 0.
- `timezone.js` is a one-line `window.getTimeZone`, loaded from `index.html`. The new
  `geolocation.js` follows the same shape.

---

## 2. Decision D1: shift vs. ride as the unit (and one workflow vs. two)

### Why a shift, not a ride

| Concern | Per-ride (discussed design) | Per-shift (proposed) |
|---|---|---|
| Deductible miles captured | Only passenger-on-board miles. Misses the miles driven while waiting for requests and en route to pickups, both widely treated as deductible business miles. That mirrors the gap in Uber's own tax summary, which also reports only on-trip miles. This is the exact gap the user wants to close. | All miles with the app on. |
| Odometer resolution | 1 mi digits on a 2–5 mi ride. The quantization error is the size of the measurement. | Errors of ±1 mi on a 100 mi shift are negligible. |
| Stacked/queued/shared rides | Overlapping odometer spans get summed twice. | One span, nothing overlaps. |
| Practicality and safety | 2 photos × 15–25 rides/day, often with a passenger aboard or while pulling away. | 2 photos/day, parked. |
| IRS substantiation | Fine, but needlessly granular. | §1.274-5T(c)(6)(i)(B) lets one *uninterrupted business use* be recorded as a single use. A shift record works when it carries date, odometer start/end, miles and business purpose (platform), with the platform's trip history as corroboration. **Assumption, flagged in §9.** |
| Downtime / idle analytics | Possible in principle, but breaks on chaining (§6). | Not computed. Within-shift utilization is already in the platform's own app. |

**Cost of reversing:** the stages, keys, capture UI and report fields are identical for a ride. Only
`item_label`, the workflow name and the `item_noun` change. The architect or user can flip this
without re-planning.

### Why two workflows, not one

- Expenses don't happen within a shift's lifecycle. Insurance, phone bills and oil changes aren't
  tied to any shift.
- Merging would push one of two bad shapes:
  - Every shift carries six expense fields, or
  - Every expense walks through Start/End stages it has no use for.
- The engine also has one `report_config` and one `period` per workflow. Mileage reads naturally
  weekly, matching platform pay weeks. Expenses read naturally monthly, matching bills.
- **Tolls and parking stay on the shift**, not in Expenses. They're incurred during, and are evidence
  of, the business use. Expenses deliberately has no tolls/parking category, so nothing gets
  double-logged.

---

## 3. Tax-substantiation adequacy: what the field set must hold

There are two kinds of requirements: what's needed per business use, and what's needed per year.

**Per business use** (Pub 463 ch. 5 / §274(d) adequate records):
- the amount, meaning the business miles
- the date
- the business purpose (and destination, which for rideshare is impractical per trip; see below)

**Per year** (Schedule C Part IV / Form 4562 Part V):
- total miles, split into business, commuting and other
- whether written evidence exists

Records must be made at or near the time.

| Requirement | Discussed design | This plan |
|---|---|---|
| Date | start_time | `start_time` (auto). Also the report's `item_date_key`. |
| Business miles | odometer delta | Derived `miles = end_odometer − start_odometer`. Never stored; recomputed (Calories precedent). |
| Business purpose | **missing** | New optional `platform` on Start (e.g. "Uber", "Lyft", "Uber+Lyft"). The purpose is "rideshare driving on <platform>". Per-trip destinations live in the platform's downloadable trip history, which the driver should export yearly (out of scope, §10). |
| Contemporaneous | photo at the time | Capture is a tap at the moment. `item_events` records actor and server time for every write and correction. That's better evidence than a typed log. |
| Personal vs. business | **missing** | Structurally solved by the shift unit: everything inside a shift is business, everything between shifts isn't. |
| Annual total miles | **missing** | Not computed in Phase 1. The odometer gap between consecutive shifts gives non-business miles, but that's cross-item (Phase 2). The driver also needs a Jan 1 / Dec 31 odometer reading. **Out of scope, called out in §10.** |
| Vehicle | **missing** | Assumes **one vehicle**. The IRS wants a separate log per vehicle. Multi-vehicle is out of scope (§10). |
| Passenger/fare amount | considered | **Not required for mileage substantiation.** Fares are income, documented by the platform's 1099s and statements. Added as an optional `earnings_usd` on End **only** for the driver's own analytics (hours vs. earnings). |
| Tolls and parking | tolls, parking | Kept as `tolls_usd` and `parking_usd`, optional on End. Business tolls and parking are deductible **in addition to** the standard mileage rate. |

**Expense categories, reworked around the standard-vs-actual rule.** Under the standard mileage
rate, vehicle operating costs (gas, maintenance/repairs, insurance, registration, depreciation,
washes) are **covered by the rate and not separately deductible**. They matter only under the
actual-expense method, or for comparing the two methods. Phone (business-use portion) and
passenger/business supplies *are* deductible on top. So:

- **Deductible alongside mileage:** `phone_usd` (business-use portion only), `supplies_usd`
  (passenger amenities, mounts, chargers, dashcam), `other_usd`.
- **Actual-expense method only (tracked for comparison):** `gas_usd`, `maintenance_usd`,
  `insurance_usd`.

The report labels make that split visible so a driver doesn't add gas on top of the mileage
deduction. A deliberate non-feature: no mileage-rate × miles "deduction estimate" card. The rate is
set by the IRS each year and can change mid-year, and baking it into config would silently go stale.

---

## 4. Odometer-from-photo: feasibility, risks, and the fallback

A vision model reading odometer digits is the same class of task as scan-vin's exact-character OCR,
not scan-plate's fuzzy estimate. In good conditions it's very feasible. The real failure modes are:

1. **Wrong number on the dash.** Modern clusters show several numbers at once: ODO, Trip A/B, range
   or distance-to-empty, speed, temperature, sometimes an average-mpg readout. Picking the trip meter
   instead of ODO is the most likely *confident* error. The prompt targets ODO explicitly and must
   return null if it can't tell which is ODO.
2. **Analog tenths drum.** Many mechanical odometers have a last drum, often in a different colour,
   that shows tenths. Concatenating it gives a reading **10× too large**.
   - The prompt asks for tenths as a decimal.
   - The client's plausibility checks (below) catch a 10× jump against the previous shift.
3. **Glare, night, motion blur, a photo through the steering wheel.** These give null or a misread
   digit. The 6↔8, 1↔7 and 3↔8 confusions are the classic ones.
4. **Units.** A cluster may be set to km. The function returns `unit`. The client rejects `km` with a
   clear message to switch the display or type the reading. A silent ×0.6214 conversion would plant
   rounding noise in a tax record.
5. **Digital odometers only light up with the ignition on.** That's fine at shift start/end, but
   worth one line in the UI hint text.

**The fallback is mandatory, not optional.** The capture block always shows both:
- **[Scan odometer]**, and
- **"or type reading: [____] [Save]"**, which goes through the same capture path. Time and area are
  still captured; only the source of the number differs.

After a capture, the reading is shown with a **"Correct reading"** inline input. A correction
rewrites only `{prefix}_odometer`, never the time or area, and adds a note saying what changed. Every
capture also adds a note recording the source, scanned vs. typed, plus the model's own note. That
follows the Scan Plate precedent, and the stage's own notes then document how each number arose.

**Client plausibility checks** (block the save and show a message; the user can still override by
typing):
- An End reading below this shift's Start: **blocked** ("lower than this shift's start reading
  48,213; rescan or type it").
- An End − Start delta over 1,000 mi: **blocked, needs typed confirmation** (the typed path accepts
  it). Catches the 10× error.
- A Start reading below the previous shift's End reading: **warn but save.** It could be a different
  vehicle, or a misread of the previous reading. The warning names both numbers.

---

## 5. Location privacy and retention

**Risk.** Raw lat/lng at every shift start and end is a precise record of where the driver lives,
since the first start of most days is home, and of their daily movements. This app's data has:
- **no delete path at all** (no DELETE policy on `items`)
- an append-only `item_events` table that permanently copies every `update_data` patch

Anything written once is effectively kept forever, in two places.

**Decision.** Never write coordinates anywhere:
1. The browser gets a position with `enableHighAccuracy: false` (coarse is all we need, and it's
   faster and kinder to the battery).
2. It **rounds to 3 decimals (~110 m)** before the position leaves the device.
3. The rounded point goes to a new `reverse-geocode` edge function. The function calls OSM Nominatim
   at `zoom=14` (suburb level) and returns a label like `"Wicker Park, Chicago"`. It logs nothing.
4. Only `{prefix}_area` (the label) is written to `item.data`.
5. If geocoding fails, `{prefix}_area` is left unset. Not a rounded-coordinate fallback, because that
   would reintroduce a stored coordinate. If location permission is denied, the capture still
   succeeds without an area. Area is optional.

**Who sees the coordinate:** the Supabase edge function in our own project, plus the OSM Foundation's
Nominatim, both rounded and in transit only. That's a third party, and the user should know (§9).

**Why a backend function rather than calling Nominatim from the browser:**
- Nominatim's policy requires an identifying User-Agent, which a browser can't set.
- Its CORS behaviour for browser callers couldn't be confirmed.
- A server proxy gives one place to swap providers later.

The user's earlier note that "geolocation needs no new backend function" still holds for *getting*
the position. Reverse geocoding is a separate need the original design introduced but didn't place.

**Retention:** area labels are kept as long as the item, which here means indefinitely. IRS records
should be kept at least 3 years after filing, so indefinite retention of *labels* is acceptable. A
general item-deletion/retention feature is out of scope (§10).

**Alternative rejected:** store a rounded coordinate (2 decimals, ~1.1 km) instead of a label. It
needs no third party, but it's less useful for a "which areas are productive" breakdown, and still
pinpoints a neighbourhood. If the user objects to OSM seeing rounded points, this is the fallback.
In that case, drop `reverse-geocode` and store `"41.88,-87.63"`-style strings in `{prefix}_area`.

---

## 6. Downtime and trip chaining

The discussed definition was `downtime = this ride's start_time − previous ride's end_time`.

**What breaks under per-ride tracking:**
- **Chained or queued rides.** The next request is accepted before the current dropoff, so the next
  "Start" capture happens before this one's "End", giving **negative downtime**.
- **Shared/pool rides overlap fully.** Negative downtime, and double-counted miles.
- **First ride of each day.** The "previous ride" is last night's. Downtime becomes 10+ hours and
  dominates any average unless there's a session-break threshold. Any threshold, say 60 min, is
  arbitrary, and it silently drops real long waits at an airport lot.
- **A missed capture** (forgot to tap End) poisons two downtime values, its own and the next ride's.
- **Ordering.** The engine orders by `created_at`, not by the captured times. A late-created item,
  for instance one entered by chat afterwards, lands out of sequence.
- **The engine can't do it at all.** `report_series` has no cross-item access. It would need a
  `lag()` window over items ordered by a timestamp key, per workflow.

**Under the shift unit**, "time between shifts" is off-duty time, not downtime, and is meaningless as
a productivity metric. Within-shift idle time isn't observable from two odometer captures. The
platform's own driver app already reports online vs. on-trip time.

**Decision:** no downtime field in Phase 1. Phase 1 instead reports **hours online per week**
(derived `end_time − start_time`) and **earnings per week**. Their ratio is the driver's real hourly
rate, the number downtime was a proxy for. The ratio needs the engine to compute `sum(a)/sum(b)` per
period (Phase 2). Until then, the driver divides two cards.

---

## 7. Implementation steps

### Step 0. Preconditions (no changes)

1. `cd /home/mmcbride/micah/claude/workflow-app && git status`. Confirm the untracked
   `supabase/migrations/20261119000000_add_closed_at_field.sql` with the user:
   - Should it be pushed (and committed) before this work? `db push` will apply it as part of Step 4.
   - Or should it be moved aside first?

   **Don't push without that answer.**
2. `supabase migration list --linked` to see what dev already has applied.
3. Ask the user for one or two real dashboard photos (one digital, ideally one analog) for the
   Step 5 curl test. Keep them **untracked**, like `plans/diet-workflow/test-plate.jpg` (personal
   photo, public repo).

### Step 1. Engine migration: `supabase/migrations/20261120000000_report_engine_signed_weights_timestamps_date_key.sql`

Four generic extensions. The header comment explains each in the style of the precedent migrations.
None changes the behaviour of an existing config. After it, Nutrition's report output must be
byte-identical (verified in Step 4).

**1a. Signed weights, plus `hidden`/`parse` validation.** `create or replace` keeps the dependency
from the CHECK intact, because the signature is unchanged. The body is identical to 20261115010000
except for the lines marked:

```sql
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
```

Why the old `> 0` rule doesn't need to survive: negative weights only change the arithmetic of
`sum(weight * value)`, which `report_series` already does generically. A zero weight stays rejected,
since it's always a config mistake.

**1b. `private.jsonb_epoch`:** a timestamp string to epoch seconds, never raising.

```sql
-- A base field with "parse": "timestamp" reads its value as epoch seconds, so a derived field can
-- subtract two timestamps (Rideshare hours online = end_time - start_time, weights +-1/3600).
-- Only ISO 8601 with an explicit offset/Z is accepted, so the result never depends on the session
-- TimeZone. Anything unparseable -> null -> ignored, same contract as jsonb_numeric. plpgsql for
-- the exception handler: a regex can't rule out e.g. month 13, and one bad value must not abort
-- the whole report. STABLE, not IMMUTABLE: the text->timestamptz cast is STABLE.
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
```

**1c. `private.item_local_date`:** reads an item's own date key.

```sql
-- item_date_key: which local calendar day an item belongs to, when its data says so. A plain
-- "YYYY-MM-DD" is taken as-is (an expense receipt's date is a calendar date, not an instant). An
-- ISO timestamp with offset is converted to p_tz's local date (a shift's start_time). Anything
-- else -> null, and the caller falls back to created_at. Never raises.
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
```

**1d. CHECK gets `item_date_key`.** Drop and re-add the constraint. Its period list and existing
clauses are unchanged:

```sql
alter table public.workflows drop constraint workflows_report_config_shape;
alter table public.workflows add constraint workflows_report_config_shape check (
  report_config is null or (
    jsonb_typeof(report_config) = 'object'
    and coalesce(report_config ->> 'period', '') in ('day', 'week', 'month')
    and private.report_fields_valid(report_config -> 'fields')
    and private.report_item_requires_valid(report_config -> 'item_requires', report_config -> 'fields')
    -- NEW: absent, or a non-empty string. ? on an object is never NULL, so the clause can't be.
    and (not (report_config ? 'item_date_key')
         or (jsonb_typeof(report_config -> 'item_date_key') = 'string'
             and (report_config ->> 'item_date_key') <> ''))
  )
);
```

Re-adding validates the existing rows. Nutrition's row passes, since it has no `item_date_key`.

**1e. `report_series`: `create or replace`, same signature and return type.** Only three CTEs change.
Every other CTE, from `segments` onward, is copied **verbatim** from 20261115010000.

```sql
  base_fields as (
    select f ->> 'key' as key, f ->> 'item_agg' as item_agg, f ->> 'period_agg' as period_agg,
           f ->> 'parse' as parse                                                    -- NEW
    from cfg, jsonb_array_elements(cfg.c -> 'fields') as f
    where not (f ? 'weights')
  ),
  -- derived_terms: unchanged
  its as (
    -- CHANGED: an item's local day is its item_date_key value if the config names one and the
    -- value parses, else created_at's local day (exactly the old behaviour when item_date_key is
    -- absent: cfg.c ->> 'item_date_key' is null, data -> null is null, item_local_date -> null).
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
    select its.id as item_id, its.stage_id, f.key,
           case when f.parse = 'timestamp' then private.jsonb_epoch(its.data -> f.key)    -- CHANGED
                else private.jsonb_numeric(its.data -> f.key) end as v,
           9223372036854775807::bigint as seq
    from its cross join base_fields f
    where its.data ? f.key
    union all
    select e.item_id, e.from_stage_id, f.key,
           case when f.parse = 'timestamp' then private.jsonb_epoch(e.data -> 'cleared' -> f.key)  -- CHANGED
                else private.jsonb_numeric(e.data -> 'cleared' -> f.key) end,
           e.seq
    from public.item_events e
    join its on its.id = e.item_id
    cross join base_fields f
    where e.event_type = 'item.stage_changed' and e.data -> 'cleared' ? f.key
  ),
```

- `::timestamp` before `date_trunc` is deliberate. Bare `date` resolves to the `timestamptz`
  overload and drags the session TimeZone in. With `::timestamp` it's the same result as before,
  computed without that dependency.
- `item_date_key` reads **live `item.data` only**. That's fine for both new configs: `date` sits on
  the only stage, and `start_time` isn't shared, so it stays live. Note this in the header.
- `report_series` stays `language sql stable security invoker`. Calling STABLE plpgsql helpers is
  fine. Cost: one subtransaction per parsed timestamp value, which is negligible at hundreds of
  shifts a year.

**Rejected alternatives for 1b–1e:**
- Store `miles` and `hours` client-side at End capture. Rejected: it breaks the "derived, never
  stored" precedent, and goes stale on a chat correction.
- Store epoch numbers alongside the ISO strings. Rejected: it clutters Details and becomes two
  sources of truth.
- Drop the expense `date` and use `created_at`. Rejected: a Dec 31 receipt logged Jan 2 lands in the
  wrong tax year.

### Step 2. Content migration: `supabase/migrations/20261120010000_add_rideshare_workflows.sql`

Header comment: why two workflows, why a shift (summarise §2), the key conventions
(`{prefix}_odometer/_time/_area`, `*_usd`), and that the report config uses Step 1's extensions.
Matched by name. Same account as Nutrition (`Joe''s Auto Repair`'s account on dev). Idempotent via
`not exists`.

```sql
insert into public.workflows (account_id, name, item_label)
select w.account_id, v.name, v.item_label
from public.workflows w
cross join (values ('Rideshare Mileage', 'shift'), ('Rideshare Expenses', 'expense')) as v(name, item_label)
where w.name = 'Joe''s Auto Repair'
  and not exists (select 1 from public.workflows x where x.name = v.name);

-- Shift: Start (initial) -> End (terminal). enforce_stage_order stays default false (2 stages, moot).
insert into public.stages (workflow_id, title, sequence_order, is_initial, is_terminal, checklist, optional_checklist)
select w.id, s.title, s.seq, s.is_initial, s.is_terminal, s.checklist, s.optional
from public.workflows w
cross join (values
  ('start', 1, true,  false,
   '["start_odometer","start_time","start_area","platform"]'::jsonb,
   '["start_area","platform"]'::jsonb),
  ('end',   2, false, true,
   '["end_odometer","end_time","end_area","tolls_usd","parking_usd","earnings_usd"]'::jsonb,
   '["end_area","tolls_usd","parking_usd","earnings_usd"]'::jsonb)
) as s(title, seq, is_initial, is_terminal, checklist, optional)
where w.name = 'Rideshare Mileage'
on conflict (workflow_id, title) do nothing;

-- Expense: one stage, both initial and terminal (a flat log). Every field optional: a missing date
-- falls back to created_at's local day via item_date_key; categories are mutually optional.
insert into public.stages (workflow_id, title, sequence_order, is_initial, is_terminal, checklist, optional_checklist)
select w.id, 'logged', 1, true, true,
  '["date","phone_usd","supplies_usd","other_usd","gas_usd","maintenance_usd","insurance_usd","note"]'::jsonb,
  '["date","phone_usd","supplies_usd","other_usd","gas_usd","maintenance_usd","insurance_usd","note"]'::jsonb
from public.workflows w
where w.name = 'Rideshare Expenses'
on conflict (workflow_id, title) do nothing;

update public.workflows
set report_config = '{
  "period": "week",
  "item_noun": "shift",
  "item_date_key": "start_time",
  "fields": [
    {"key": "miles",  "label": "Business miles", "unit": "mi", "period_agg": "sum",
     "weights": {"end_odometer": 1, "start_odometer": -1}},
    {"key": "hours",  "label": "Hours online",   "unit": "h",  "period_agg": "sum",
     "weights": {"end_time": 0.000277777777777778, "start_time": -0.000277777777777778}},
    {"key": "earnings_usd", "label": "Earnings", "unit": "$", "unit_position": "prefix",
     "item_agg": "sum", "period_agg": "sum"},
    {"key": "tolls_usd",    "label": "Tolls",    "unit": "$", "unit_position": "prefix",
     "item_agg": "sum", "period_agg": "sum"},
    {"key": "parking_usd",  "label": "Parking",  "unit": "$", "unit_position": "prefix",
     "item_agg": "sum", "period_agg": "sum"},
    {"key": "start_odometer", "hidden": true, "item_agg": "last", "period_agg": "last"},
    {"key": "end_odometer",   "hidden": true, "item_agg": "last", "period_agg": "last"},
    {"key": "start_time", "hidden": true, "parse": "timestamp", "item_agg": "last", "period_agg": "last"},
    {"key": "end_time",   "hidden": true, "parse": "timestamp", "item_agg": "last", "period_agg": "last"}
  ]
}'::jsonb
where name = 'Rideshare Mileage' and report_config is null;

update public.workflows
set report_config = '{
  "period": "month",
  "item_noun": "expense",
  "item_date_key": "date",
  "fields": [
    {"key": "phone_usd",       "label": "Phone (business share)",          "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "supplies_usd",    "label": "Supplies",                        "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "other_usd",       "label": "Other",                           "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "gas_usd",         "label": "Gas (actual-expense method only)", "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "maintenance_usd", "label": "Maintenance (actual-expense method only)", "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "insurance_usd",   "label": "Insurance (actual-expense method only)",   "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"}
  ]
}'::jsonb
where name = 'Rideshare Expenses' and report_config is null;
```

Notes on the configs:
- **Miles and hours are derived**, so they exist only for shifts with both captures. An in-progress
  shift contributes no miles, which is correct.
- **`item_requires` is not used.** A shift with tolls but a failed End capture should still count
  its tolls.
- **The hours weight** is 1/3600 to 15 significant digits. The error is under 1e-12 h per shift.
- **Hidden base fields use `last`/`last`.** Their values are never shown, and they exist only so the
  derived fields' validation (components must be base fields in `fields`) passes.
- **Known gap: there is no expense "Total" card.** A derived total over categories would be null for
  every expense that lacks *some* category, because of the every-component rule. That needs a
  derived-field "missing = 0" option, which is a Phase 2 candidate.
- **Category list rationale** is in §3. Order puts deductible-alongside-mileage first. Labels are in
  config, not code.

### Step 3. Dev check scripts

- **`scripts/report_series_dev_check.sql`:**
  - Move the "negative weight" case (around line 96–97) from the reject list to a new
    **accept** assertion.
  - Keep "zero weight" in the reject list.
  - Add reject cases:
    - `"hidden": "yes"`
    - `"parse": "date"`
    - `parse` on a derived field
    - `"item_date_key": ""`
    - `"item_date_key": 5`
- **New `scripts/rideshare_report_dev_check.sql`.** Same style as the existing script: one `do $$`
  block that always ends in an exception, success = message starting `PASS`. All writes roll back.
  Test items are back-dated to the isolated week of 2026-01-05, `America/Chicago`. Cases:
  1. A shift with start 48,000 / end 48,123, start 2026-01-05T14:00:00Z, end 2026-01-05T22:30:00Z.
     A second shift crossing local midnight, with start_time on 2026-01-06 local. Expect
     `miles` = sum, `hours` = 8.5 + the second shift's hours, both bucketed to week 2026-01-05.
  2. An in-progress shift (start only) contributes to neither miles nor hours, but is in
     `item_count`.
  3. A malformed `end_time` (`"yesterday"`, `"2026-13-01T00:00:00Z"`) gives no hours for that item
     and **no error**.
  4. **Expense `item_date_key`.** An expense created (`created_at` updated) on 2026-01-02 with
     `"date": "2025-12-31"` buckets to December 2025 when queried with `p_from`/`p_to` spanning both
     months. Without a parseable date, it falls back to `created_at`.
  5. **Regression:** run the shipped Nutrition config over the existing test fixtures. Simpler and
     stronger: just re-run `report_series_dev_check.sql` unchanged apart from the edit above.

  Plus a snapshot of real data: before Step 4, record
  `select * from report_series(<nutrition id>, '2026-11-01', '2026-11-30', 'America/Chicago')`;
  after Step 4, diff it. It must be identical.

### Step 4. Push migrations to dev and verify

```bash
cd /home/mmcbride/micah/claude/workflow-app
supabase db push --linked --dry-run   # expect only the expected files (see Step 0 re: 20261119000000)
supabase db push --linked
```

Then run both check scripts and the Nutrition before/after diff, the same way the generic-report
work ran `report_series_dev_check.sql` against dev.

### Step 5. Edge functions

**5a. `supabase/functions/scan-odometer/index.ts`** has the scan-plate shape: 422 for "unreliable",
502 for upstream failure. The core:

```ts
// Single-purpose odometer reading from a dashboard photo (2026-11-20). Same shape and reasoning
// as scan-vin/scan-plate: one-shot, no chat history, photo never stored. Exact-digit OCR like
// scan-vin, but a cluster shows several numbers (trip A/B, range, speed) and analog odometers
// have a tenths drum, so the model must say which number it read and the caller validates.
import Anthropic from "npm:@anthropic-ai/sdk@0.32.1";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-5-5";
// ... RequestBody, corsHeaders, OPTIONS/405/401/400 handling identical to scan-plate ...

type OdometerReading = { reading: number; unit: "mi" | "km"; note: string };
const MAX_READING = 1_999_999; // no real odometer exceeds this; catches concatenated digits

function parseReading(raw: string): OdometerReading | null {
  let p: unknown;
  try { p = JSON.parse(raw); } catch { return null; }
  if (typeof p !== "object" || p === null) return null;
  const { reading, unit, note } = p as Record<string, unknown>;
  if (reading === null) return null;                       // model said "can't tell"
  if (typeof reading !== "number" || !Number.isFinite(reading)) return null;
  if (reading < 0 || reading > MAX_READING) return null;
  if (Math.round(reading * 10) !== reading * 10) return null; // at most one decimal (tenths)
  if (unit !== "mi" && unit !== "km") return null;
  return { reading, unit, note: typeof note === "string" ? note : "" };
}

// system prompt (max_tokens 256):
// "You are given a photo of a vehicle's instrument cluster. Find the TOTAL ODOMETER reading
//  (often labelled ODO) -- NOT a trip meter (TRIP, TRIP A/B, A/B), NOT range or distance-to-empty,
//  NOT speed, temperature or fuel economy. On a mechanical odometer, a final drum in a different
//  colour (or separated) shows tenths: report it as a decimal (48213.4), never append it as a
//  whole digit. Respond with ONLY a JSON object, no markdown:
//  {\"reading\": <number or null>, \"unit\": \"mi\" | \"km\" | null, \"note\": \"<short>\"}.
//  Use null for reading if no odometer is clearly legible, or if you cannot tell which number is
//  the total odometer. In note, say which label you read it next to, and flag any digit you were
//  unsure of."
// response: 200 {reading, unit, note} | 422 {error: "..."} | 502 on exception.
```

**5b. `supabase/functions/reverse-geocode/index.ts`** has the same CORS and bearer boilerplate.

```ts
// Coordinates in, coarse area label out (2026-11-20). Coordinates are never logged or stored --
// the caller has already rounded them to 3 decimals, and only the label is written to item.data.
// Server-side (not browser fetch) so we can send an identifying User-Agent per Nominatim's usage
// policy. One call per shift capture, i.e. far under its 1 req/s ceiling.
type Body = { lat: number; lng: number };
// validate: finite numbers, -90..90 / -180..180, else 400
const url = `https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=14&addressdetails=1` +
            `&lat=${lat.toFixed(3)}&lon=${lng.toFixed(3)}`;
const res = await fetch(url, { headers: {
  "User-Agent": "workflow-engine/1.0 (+https://datasciguycode.github.io/workflow-engine/)",
  "Accept-Language": "en",
}, signal: AbortSignal.timeout(5000) });
// a = json.address; local = a.suburb ?? a.neighbourhood ?? a.city_district ?? a.quarter;
// city = a.city ?? a.town ?? a.village ?? a.county;
// area = [local, city].filter(Boolean).join(", ") || null
// 200 {area} (area may be null); upstream failure -> 200 {area: null} (location is best-effort).
```

**5c. `supabase/config.toml`:** add explicit blocks, following the scan-plate precedent and its
comment:

```toml
[functions.scan-odometer]
verify_jwt = true

[functions.reverse-geocode]
verify_jwt = true
```

**5d. Check, deploy and smoke-test:**

```bash
deno check supabase/functions/scan-odometer/index.ts supabase/functions/reverse-geocode/index.ts
supabase functions deploy scan-odometer   --project-ref utwyvtbzesswpoihmlic --use-api
supabase functions deploy reverse-geocode --project-ref utwyvtbzesswpoihmlic --use-api
supabase functions list --project-ref utwyvtbzesswpoihmlic   # both ACTIVE, verify_jwt true
```

Smoke tests:
- curl `scan-odometer` with the user's dashboard photo(s), using a user JWT exactly as in the
  scan-plate plan's Step 7.
- Expect the ODO reading, not a trip meter.
- Also send one deliberately bad photo (blurred or dark) and expect 422.
- curl `reverse-geocode` with a known public point (a downtown landmark, **not** the user's home)
  and expect a sensible label.

No new secrets: `ANTHROPIC_API_KEY` is already project-wide, and Nominatim needs no key.

### Step 6. Web changes

**6a. `web/wwwroot/js/geolocation.js`** (new), loaded in `index.html` right after
`js/timezone.js`:

```js
// Coarse position for shift capture; resolves null on denial/timeout/unsupported, never rejects.
window.getApproxPosition = () => new Promise(resolve => {
  if (!navigator.geolocation) return resolve(null);
  navigator.geolocation.getCurrentPosition(
    p => resolve({ lat: Math.round(p.coords.latitude * 1000) / 1000,
                   lng: Math.round(p.coords.longitude * 1000) / 1000 }),
    () => resolve(null),
    { enableHighAccuracy: false, timeout: 10000, maximumAge: 120000 });
});
```

Rounding happens here, in the browser, so a precise coordinate never leaves the device.

**6b. `web/Services/WorkflowApiClient.cs`:**
- `public record OdometerScanResult(double Reading, string Unit, string Note);`
- `ScanOdometerAsync(base64, mediaType)` returns `OdometerScanResult?`. It returns null on 422 and
  throws otherwise, exactly like `ScanFoodPhotoAsync`.
- `ReverseGeocodeAsync(double lat, double lng)` returns `string?`. It **never throws**: it catches
  everything and returns null, because area is best-effort.
- `ReportField` gets `bool Hidden`. `ParseReportConfig` reads `f["hidden"]` as a bool, default
  false. `parse` and `item_date_key` need no client handling; they're server-only.

**6c. `web/Pages/WorkflowDetail.razor`, list visibility.** Replace the `VisibleItems()` predicate.
"Closed" now means: **in a terminal stage that isn't also the initial stage, with that stage's
required fields filled.**

```csharp
private bool IsClosed(ItemSummary i) =>
    _stages!.FirstOrDefault(s => s.Id == i.StageId) is { IsTerminal: true, IsInitial: false } st
    && st.Checklist.Except(st.OptionalChecklist)
         .All(f => i.Data.TryGetPropertyValue(f, out var v) && v is not null);
```

Effect on each workflow:
- **Mechanic `closed`:** its only field, `closed_at`, is optional, so the required set is empty.
  Hidden exactly as today.
- **Nutrition `dinner`:** all fields are optional. Hidden exactly as today.
- **Expenses `logged`:** initial, so never hidden. That fixes the empty list.
- **Shift `end`:** stays visible until `end_odometer` and `end_time` are captured. That fixes the
  disappearing in-progress shift.

Rejected alternative: special-case by `item_label`. The rule above is generic and changes nothing
for existing workflows.

**6d. `WorkflowDetail.razor`, display name.** For non-job workflows, append the local time
`HH:mm` when another loaded item has the same local date:
`"Logged 2026-11-19 14:05"`, `"End 2026-11-19 06:30"`. Nutrition is one item per day, so its names
don't change.

**6e. `WorkflowDetail.razor`, `_usd` display.** Extend the unit-suffix table with a prefix flag:
`("_usd", "$", prefix: true)`. A filled field then renders as `$12.50 Tolls`, and `FieldLabelAndUnit`
returns a prefix/suffix flag. The existing `_g`/`_lbs` rendering is unchanged.

**6f. `WorkflowDetail.razor`, capture block.**

Gating:
- The block shows when `_selectedStageId == _selectedItem.StageId`, matching the existing
  current-stage-only rule and comment.
- The current stage's checklist must contain a key ending in `_odometer`.
- `prefix` = that key minus `_odometer` (`start` / `end`).
- `{prefix}_time` and `{prefix}_area` are written only if they're also on that stage's checklist.

That makes it a convention, not a Shift-specific hardcode, in the same spirit as the
`vin`/`protein_g` gates.

UI:

```
[ Scan odometer ]   or type reading: [______] [Save]
hint: "Ignition on so the odometer is lit; photograph the ODO number, not a trip meter."
(after a capture)  Odometer 48,213 -- Correct reading: [______] [Fix]
(warnings/errors line, same styling as _vinScanError)
```

Flow for `CaptureAsync(prefix, double reading, string source, string? modelNote)`:
1. Take `capturedAt` when the photo is selected (in `OnChange`), or when Save is tapped for a typed
   reading.
   - Format: `DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)`.
   - No fractional seconds, so the SQL regex and the `timestamptz` cast are trivially safe.
   - `FieldText` already renders it in local time.
2. In the photo path, start `areaTask = GetAreaAsync()` **concurrently** with the scan, as soon as
   the file is picked. `GetAreaAsync` calls JS `getApproxPosition` and then `ReverseGeocodeAsync`.
   It never throws and returns null on any failure.
3. Scan: resize with `RequestImageFileAsync("image/jpeg", 1600, 1600)` as Scan VIN does, then call
   `ScanOdometerAsync`.
   - null → error "Couldn't read the odometer -- try again, or type the reading."
   - `Unit == "km"` → error "Odometer appears to be in km -- switch the display to miles or type
     the reading in miles."
4. Plausibility (§4): compare against `{start}_odometer` on this item (for End), and against the
   latest `end_odometer` among other `_items`, ordered by `end_time`.
   - A block shows the message and keeps the value in the typed box for one-tap override.
   - A warn saves and shows the message.
5. Build the patch:
   - Always `{prefix}_odometer`.
   - `{prefix}_time` **only if not already set**. A re-scan after a misread mustn't move the shift
     start.
   - `{prefix}_area` only if not already set **and** non-null.
6. `UpdateDataAsync`, then `AddNoteAsync(item, $"{Prefix} odometer {reading:N1} mi ({source}){modelNote}", _selectedStageId)`.
7. Reload items and notes (same tail as `OnVinPhotoSelected`).

"Fix" writes only `{prefix}_odometer`, plus a note `"Corrected {prefix} odometer {old} -> {new}"`.

Stage advance stays manual via the existing **Complete Stage** button. It appears once
`start_odometer` and `start_time` (the required fields) are present. Auto-advancing after a Start
capture was considered and rejected: it saves one tap, but immediately shows the End capture button,
and a stray tap there would end a shift seconds after starting it.

**6g. `web/Pages/WorkflowReport.razor`:** `@foreach (var field in report.Fields.Where(f => !f.Hidden))`.
A unit of `"mi"` or `"h"` already formats as `0.#` via the default branch.

**6h. Build:** `dotnet build web/`, then a local run for the UI sanity pass. Deploying (push to
`main`) only happens once the user asks to commit and push.

### Step 7. Live checks on a phone (dev site)

1. **Expenses:** "+ New Expense", then chat "$42.10 gas yesterday". The agent sets `gas_usd` and
   `date`. The item stays in the list. The Report's month card shows $42.10, and Report has no Total
   card. Log one dated last month and confirm it lands in last month.
2. **Shift:** "+ New Shift", then Scan odometer at the car.
   - Location permission prompt appears, then the reading, time and area show.
   - Complete Stage, then on End, Scan.
   - Test a deliberately lower typed reading: it should be blocked.
   - Add tolls via chat.
   - The Report week shows miles, hours and tolls matching hand arithmetic.
   - The shift drops off the list only after End's capture.
3. Deny location permission once. The capture still saves, without an area.
4. Re-check the Nutrition report page and the mechanic Jobs list. Unchanged.

---

## 8. Risks, edge cases, rollback

- **Engine regression on Nutrition.** Mitigated by the verbatim copy of the untouched CTEs, the
  updated dev check, and the before/after diff of real Nutrition output. `create or replace` keeps
  the signature, so no client changes are forced.
- **A CHECK re-add failing on existing rows.** It can't, unless a row violates clauses that are
  already checked today. If the push fails there, the whole migration rolls back (single
  transaction).
- **Clock skew.** `{prefix}_time` comes from the phone's clock. Phones sync time over the network,
  so the risk is accepted. `item_events.created_at` is the server-side corroboration.
- **A shift spanning midnight or a week boundary** belongs to its start date or week
  (`item_date_key = start_time`). That's intended.
- **Negative miles or hours** from a bad chat correction (the agent writes an untyped value). The
  report would show a reduced sum. The client checks only cover the capture path. Accepted, and
  noted in the header comment.
- **Agent behaviour.** The agent sees stage checklists in its system prompt, so it can fill
  `gas_usd`, `date`, `platform`, `tolls_usd` from chat. Assumption (§9): it will pick the right
  `*_usd` key from "spent $40 on gas". If it doesn't reliably, a one-line prompt hint is a later
  tweak; no agent-loop change is planned.
- **Nominatim availability or policy changes.** Area is best-effort and never blocks a capture.
- **Rollback:**
  - **Web:** revert the commit and push.
  - **Functions:** `supabase functions delete scan-odometer|reverse-geocode --project-ref utwyvtbzesswpoihmlic`.
  - **Content:** delete the two workflows' `item_events`, then `items`, `stages` and `workflows`, as
    the CLI role, matched by name.
  - **Engine:** a down migration that re-issues the 20261115010000 definitions of
    `report_fields_valid` and `report_series`, re-adds the original CHECK, and drops `jsonb_epoch`
    and `item_local_date`. That only works once no config uses the new keys, so content goes first.

---

## 9. Assumptions I couldn't verify

1. **Treas. Reg. §1.274-5T(c)(6)(i)(B)'s "uninterrupted business use"** lets a whole shift be one
   log entry, with the platform's trip history as supporting detail. I'm fairly confident, but a tax
   professional should confirm. If it's wrong, the per-ride reversal in §2 is cheap.
2. Whether miles from home to the first pickup, with the app on, are business or commuting is
   **genuinely contested**. The plan records the shift boundary as the moment the driver taps Start.
   Where to tap is the driver's call.
3. Nominatim's current usage policy permits this volume via a server proxy with an identifying
   User-Agent. Secondary sources say a 1 req/s maximum with identification required; I wasn't able
   to fetch the official policy page itself. Check
   https://operations.osmfoundation.org/policies/nominatim/ before Step 5.
4. iOS Safari shows the geolocation permission prompt for a `getCurrentPosition` call made right
   after an `InputFile` change event, rather than requiring it inside the original tap handler.
   If it doesn't, call `getApproxPosition` from a pointerdown on the Scan button's label instead.
5. `claude-sonnet-5-5` reliably tells ODO from trip meters on the user's own cluster. Step 5d's
   smoke test with the user's real dashboard is the check.
6. The 2026 standard mileage rate is deliberately not used anywhere. Sources conflict, including a
   mid-year change.

---

## 10. Out of scope (deliberately)

- **Phase 2 engine features**, each needing its own plan:
  - group-by dimension (per-area breakdown, per-category with a free-text category)
  - ratio-of-sums fields (earnings/hour)
  - cross-item window (odometer gap between shifts = personal miles, downtime)
  - derived "missing = 0" (expense Total)
  - a per-workflow period switcher (week/month/year in one report)
- Annual business-use % and the Schedule C line 44 split. These need Jan 1 / Dec 31 readings plus the
  cross-item gap.
- Multi-vehicle support.
- Storing odometer photos as evidence (needs a Storage bucket and retention policy; the established
  pattern discards photos).
- Receipt scanning for expenses.
- Importing or exporting platform trip history or a CSV/PDF tax export.
- Item deletion and retention controls.
- Any mileage-rate deduction estimate.
- Prod. Nothing is ported; this joins the dev-only list in `PROGRESS.md` at the next milestone.
