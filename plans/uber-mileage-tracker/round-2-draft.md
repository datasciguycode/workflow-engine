# Rideshare mileage + expense tracking: round-2 draft plan

Status: draft for review (revision of `round-1-draft.md`). Dev only (`workflow-engine-test`, ref
`utwyvtbzesswpoihmlic`). Nothing in this plan touches `/home/mmcbride/micah/claude/workflow-app-prod`.
Nothing has been executed. The only thing run while writing it was a read-only
`supabase migration list --linked` (Step 0).

Not tax advice. The tax points below are my reading of IRS Pub 463 ch. 5, Treas. Reg. §1.274-5T,
and the case-law summary in `round-1-sanity-check.md`. They're here so the data model collects the
right things. They don't replace a tax professional.

---

## 0. TL;DR: what changed from the discussed design, and why

The discussed design had two parts:
- **Ride:** a Start and End odometer photo per ride, with location and time, plus derived miles,
  downtime and area productivity.
- **Expenses:** a single-stage log with category, amount and date.

After checking it against the codebase and the tax rules, seven changes are load-bearing. Each has
its own section.

1. **The unit of tracking is a *shift* (app on to app off), not a single ride** (§2). Four reasons:
   - Per-ride spans miss the miles driven while waiting and while heading to a pickup. Those are
     often 30–50% of business miles.
   - Odometers resolve to 1 mile. On a 3-mile ride that's ±33% error.
   - Stacked or queued trips get double-counted.
   - Two dashboard photos per ride, with a passenger in the car, isn't practical or safe.

   Stages, fields and capture UI are identical either way, so reversing this is cheap.
2. **This app's shift log is one half of the tax record, not all of it** (§3). Tax Court has
   rejected bare start/end odometer logs that had no corroboration. The other half is the
   platform's own trip history and tax summary, which the driver downloads. Phase 1 adds a
   permanent reminder to save those, in the capture UI and on the Report page. It's static text
   plus one optional config key.
3. **`platform` (the business purpose) is required on Start, and pre-filled from the last shift**
   (§3, Step 6f). Leaving it blank can't silently pass.
4. **The report engine gets four small, generic extensions** (Step 1):
   - signed weights
   - `hidden` fields
   - `parse: "timestamp"` base fields
   - a top-level `item_date_key`

   Together these cover miles, hours, tolls, parking and earnings. Downtime, earnings-per-hour and
   the per-area breakdown are deferred to Phase 2 (§6). The `parse: "timestamp"` extension buys
   only the "Hours online" card. It's kept, but it's built so it can be cut cleanly (§7, Step 1
   note).
5. **Expense categories are one amount key each** (`gas_usd`, `phone_usd`, ...), arranged around the
   standard-vs-actual mileage rule (§3).
6. **Raw GPS coordinates are never stored.** The browser rounds them to about 110 m. A new
   `reverse-geocode` edge function sends them to **LocationIQ** (free tier, licensed for app
   traffic) and gets back a neighbourhood/city label. Only the label is written. Round 1 used the
   public OSM Nominatim instance, which was dropped (§5).
7. **The odometer scan always has a manual path**, plus a correction input and plausibility checks.
   Every write is audited by `item_events` (§4).

---

## 1. Codebase facts this plan relies on (verified by reading the code, 2026-11-19)

- **Report engine** (`20261115010000_add_workflow_report_config.sql`):
  - `report_fields_valid` rejects any weight `<= 0`.
  - A derived field's weights must name base fields that are in `fields`.
  - A derived field has a per-item value only when **every** component is non-null.
  - `report_series` buckets by `items.created_at` in `p_tz`. It reads values through
    `private.jsonb_numeric`, which accepts numbers and numeric strings only.
  - `period` is one of `day|week|month`.
  - The CHECK on `workflows.report_config` validates only the keys it names. An extra top-level key
    such as `note` passes untouched. The `item_noun` key already works this way.
- **`scripts/report_series_dev_check.sql` lines 94–97** have `-- zero weight` and
  `-- negative weight` in the reject list. Signed weights break the negative-weight assertion, so
  the script must be updated in the same change.
- **Scripts run against dev** with `supabase db query --linked -f <file>`. There's no psql to dev.
  This is the generic-report precedent.
- **`web/Services/WorkflowApiClient.cs`:**
  - `ReportField(Key, Label, Unit, bool UnitPrefix, ...)` and `ReportConfig(Period, ItemNoun, Fields)`.
    `ParseReportConfig` reads `item_noun` at line ~102.
  - `GetItemsAsync` (line 207) fetches **every item in the workflow**, in all stages, ordered by
    `updated_at.desc`, with no client-side paging. It's subject only to PostgREST's `max-rows`
    (Supabase default 1000).
  - `ItemSummary(Id, StageId, JsonObject Data, DateTimeOffset CreatedAt)`.
  - `StageSummary(..., List<string> Checklist, List<string> OptionalChecklist)`.
- **`web/Pages/WorkflowDetail.razor`:**
  - **Lines 81–96:** the stage checklist renders filled fields with
    `var (baseLabel, unit) = FieldLabelAndUnit(field);`, then
    `@($"{FieldText(field, v)}{unit} {baseLabel}{star}")` when `unit.Length > 0`. The unit is glued
    **after** the value at the call site.
  - **Lines 697–707:** `FieldUnitSuffixes` is `(string Suffix, string Unit)[]` with `_g` and
    `_lbs`. `FieldLabelAndUnit` returns `(Label, Unit)`. Line 81 is its only caller.
  - **Line 328:** the job-overview "Details" list uses `ChecklistLabel(key): FieldText(key, value)`.
    It's unaffected by unit handling.
  - **Lines 551–567:** `FieldText` formats any string value whose key contains `date`/`time` or
    ends `_at` as `"MMMM d, yyyy, h:mm tt"`.
  - **Lines 596–599:** `VisibleItems()` hides every item whose stage `IsTerminal`, unless
    `_showClosed` is set. Two consequences:
    - A single-stage (initial+terminal) Expenses workflow would show an empty list.
    - A shift would vanish the moment it moves to End.
  - **Lines 629–633:** `ItemDisplayName` gives non-job items
    `"{StageTitle(stageId ?? item.StageId)} {item.CreatedAt.ToLocalTime():yyyy-MM-dd}"`.
  - **Lines 101–124:** the Scan VIN block is gated on
    `_selectedStageId == _selectedItem.StageId && checklist.Contains("vin")`. It uses a hidden
    `InputFile` behind a label-wrapped button and the `_vinScanError` message styling.
  - **Lines 780–793:** `DoneNextStage()` (the **Complete Stage** button) appears only on the item's
    current stage, once every `checklist − optional_checklist` key is non-null in `item.data`.
- **`move_stage`** saves and restores only keys **shared** between the departing and arriving
  stages. Shift's `start_*` and `end_*` keys aren't shared, so they all stay live in `item.data`.
- **`update_data`** is a top-level merge, where `null` deletes a key. Every call writes an
  `item.data_changed` event to `item_events`, which gives a free audit trail.
- **Uniqueness:**
  - `stages` **has** `unique (workflow_id, title)`
    (`20261012035437_phase0_core_schema.sql` line 39), so `on conflict (workflow_id, title)` is a
    real conflict target. Nutrition's migration already relies on it.
  - `workflows.name` has **no** unique constraint, so this plan uses `where not exists` for
    workflows.
- **Tables referencing `workflows`/`stages`/`items`:** `stages`, `items`, `item_events`
  (`item_id`, `from/to_stage_id`, `stage_id`), `chat_messages` (`workflow_id NOT NULL`, `item_id`,
  `stage_id`) and `agent_events` (`workflow_id NOT NULL`, `item_id`). `item_events`,
  `chat_messages` and `agent_events` are append-only **by RLS policy only**. There's no trigger, so
  the CLI's privileged role can delete from them (needed for the content rollback, §8).
- **Edge functions:**
  - `scan-vin` and `scan-plate` are single-file Deno functions using
    `npm:@anthropic-ai/sdk@0.32.1` and `MODEL = "claude-sonnet-5-5"`.
  - Both use the same CORS and bearer checks, and never store the photo.
  - `scan-plate` returns 422 for "judged unreliable".
  - `config.toml` line ~401 has `[functions.scan-plate] verify_jwt = true`, with its reason.
- **Deploy conventions:**
  - Functions: `supabase functions deploy <name> --project-ref utwyvtbzesswpoihmlic --use-api`.
    Always name the function.
  - Migrations: `supabase db push --linked --dry-run`, then `supabase db push --linked`.
  - Web: a push to `main` deploys to Pages.
  - Content migrations match by name/title, never by id.
- **`20261119000000_add_closed_at_field.sql`:**
  - Untracked in git.
  - **Already applied to dev.** `supabase migration list --linked`, run 2026-11-19, shows
    `local 20261119000000 / remote 20261119000000`. Every other local migration is also applied.
  - It adds an *optional* `closed_at` to the mechanic `closed` stage. See Step 0 for what this
    means for this plan.
- `index.html` line 89 loads `js/timezone.js`. The new `geolocation.js` goes right after it.

---

## 2. Decision D1: shift vs. ride as the unit (and one workflow vs. two)

### Why a shift, not a ride

| Concern | Per-ride (discussed design) | Per-shift (proposed) |
|---|---|---|
| Deductible miles captured | Only passenger-on-board miles. Misses the miles driven while waiting and en route to pickups, the same gap the platform's own "on-trip miles" figure has. Closing that gap is the user's goal. | All miles with the app on. |
| Odometer resolution | ±1 mi on a 2–5 mi ride. | ±1 mi on a 100 mi shift, which is negligible. |
| Stacked/queued/shared rides | Overlapping spans get summed twice. | One span, no overlap. |
| Practicality and safety | 2 photos × 15–25 rides/day, often with a passenger aboard. | 2 photos a day, parked. |
| IRS substantiation | Needlessly granular, and *still* needs platform corroboration. | The regulation's aggregation rules for business use, Treas. Reg. §1.274-5T(c)(6)(i)(**C**), allow an uninterrupted business use to be recorded as a single use. A shift record carries the date, start/end odometer, miles and business purpose (the required `platform` field). **The platform's trip history is the corroboration (§3).** Assumption flagged in §9. |
| Downtime analytics | Breaks on chaining (§6). | Not computed. |

**Cost of reversing:** only `item_label`, the workflow name and `item_noun` change.

### Why two workflows, not one

- Expenses aren't tied to the shift lifecycle.
- Merging would force one of two bad shapes:
  - every shift carries the expense fields, or
  - every expense walks through Start and End.
- The engine allows one `report_config` and one `period` per workflow. Mileage reads naturally
  weekly (matching pay weeks). Expenses read naturally monthly (matching bills).
- **Tolls and parking stay on the shift.** Expenses deliberately has no tolls/parking category, so
  nothing gets double-logged.

---

## 3. Tax substantiation: what this app proves, and what it doesn't

**Per business use** (Pub 463 ch. 5 / §274(d) adequate records), the record needs:
- the amount (business miles)
- the date
- the business purpose

It must be made at or near the time.

**Per year** (Schedule C Part IV / Form 4562 Part V), the record needs:
- total miles, split into business, commuting and other
- whether written evidence exists

**How the case law changes the framing** (per `round-1-sanity-check.md`; I didn't read the opinions
myself):
- In *Brown*, a log with daily start/stop odometer columns was rejected for lack of
  corroborating documentation.
- In *Ressen*, periodic entries were accepted, but on the strength of credible, corroborated
  detail.

So a bare start/end odometer log is the weak kind of record. This plan therefore claims less than
round 1 did:

- **This app's shift log records the *total* app-on business miles, including the deadhead and
  waiting miles the platform's tax summary leaves out.** It's contemporaneous, timestamped by the
  server, and every correction is audited.
- **The platform's own trip history and annual tax summary are the corroborating record.** They
  give per-trip detail, online vs. on-trip miles, and the platform name. The two together are the
  substantiation. Neither is enough alone.
- **Phase 1 makes this visible.** It costs no new fields or engine work:
  - A static tip under the odometer capture block: *"For taxes, also download your Uber/Lyft
    weekly trip history and annual tax summary and keep them with this log. This log covers the
    miles they don't report (driving to pickups, waiting)."*
  - A `note` key in both workflows' `report_config`, shown at the top of the Report page. Mileage
    uses the same text. Expenses uses: *"Keep receipts. Gas, maintenance and insurance count only
    under the actual-expense method, not on top of the standard mileage rate."*

| Requirement | This plan |
|---|---|
| Date | `start_time` (auto). Also the report's `item_date_key`. |
| Business miles | Derived `miles = end_odometer − start_odometer`. Never stored. |
| Business purpose | **Required** `platform` on Start ("Uber", "Lyft", "Uber+Lyft"). Pre-filled from the driver's previous shift and editable (Step 6f). Complete Stage can't appear without it. |
| Destinations | Impractical per shift. They're in the platform trip history (the reminder above). |
| Contemporaneous | A tap at the moment. `item_events` records actor and server time for every write and correction. |
| Personal vs. business | Everything inside a shift is business. Everything between shifts isn't. |
| Annual total miles | **Not in Phase 1.** Needs the cross-item gap plus Jan 1 / Dec 31 readings (§10). |
| Vehicle | One vehicle assumed (§10). |
| Fares | Income, documented by the platform. `earnings_usd` is optional and used only for the driver's own analytics. |
| Tolls and parking | `tolls_usd` and `parking_usd`, optional on End. Deductible on top of the standard rate. |

**Expense categories** (standard-vs-actual rule). Under the standard mileage rate, vehicle operating
costs are covered by the rate and aren't separately deductible.

- **Alongside mileage:**
  - `phone_usd` (business-use share)
  - `supplies_usd` (passenger amenities, chargers, small accessories)
  - `other_usd`
- **Actual-expense method only (tracked for comparison):**
  - `gas_usd`
  - `maintenance_usd`
  - `insurance_usd`

One caveat on supplies: a permanently installed or costlier item, such as a wired-in dashcam, may
be an asset to depreciate rather than a supply. The category name doesn't decide that, and a tax
professional should.

Deliberately left out: a mileage-rate × miles "deduction estimate" card, because the IRS rate
changes and would go stale in config.

---

## 4. Odometer-from-photo: feasibility, risks, fallback

This is exact-digit OCR, like scan-vin. The failure modes:

1. **Wrong number on the dash** (trip A/B, range, speed). This is the most likely *confident* error.
   The prompt targets ODO and must return null if it can't tell which number is ODO.
2. **Analog tenths drum.** Appending it as a whole digit reads 10× too large. The prompt asks for
   tenths as a decimal, and the plausibility checks catch a 10× jump.
3. **Glare, night, blur.** These give null or a misread digit (6↔8, 1↔7, 3↔8).
4. **Units.** The function returns `unit`. The client rejects `km` with a message. There's no
   silent conversion.
5. **Digital clusters light up only with the ignition on.** The UI hint says so.

**The fallback is mandatory.** The capture block always shows [Scan odometer] **and** "or type
reading: [____] [Save]". After a capture, a "Correct reading" input rewrites only
`{prefix}_odometer` and adds a note. Every capture adds a note recording its source (scanned or
typed) and the model's own note.

**Client plausibility checks:**
- **End below this shift's Start:** blocked.
- **End − Start over 1,000 mi:** blocked. The typed path accepts it after re-entry.
- **Start below the previous shift's End:** saves, with a warning that names both numbers.

**Residual risk, accepted:** these bounds catch gross errors, not a plausible single-digit misread.
For example, 48,213 read as 48,813 clears both checks and adds 600 phantom miles.

Mitigations:
- The reading is shown prominently after capture, next to the Correct input.
- The model's note flags digits it was unsure of.
- The platform's online-miles figure lets the driver cross-check a week's total.

A tighter check, such as flagging when a shift's miles are far above the driver's typical
miles per hour, needs history and is a Phase 2 candidate.

---

## 5. Location privacy and retention

**Risk.** A shift-start location is usually home. This app has no delete path for `items`, and
`item_events` permanently copies every patch. Anything written is effectively kept forever.

**Design, unchanged in shape from round 1:**
1. The browser takes a coarse position (`enableHighAccuracy: false`).
2. It **rounds to 3 decimals (~110 m)** before anything leaves the device.
3. The rounded point goes in a **POST JSON body**, not the query string, to the new
   `reverse-geocode` edge function. The function has no `console.log` of coordinates.
4. The function calls LocationIQ's reverse endpoint at `zoom=14` and returns a label like
   `"Wicker Park, Chicago"`.
5. Only `{prefix}_area` (the label) is written. On any failure or denied permission, area is left
   unset and the capture still succeeds.

**Provider: LocationIQ, not public Nominatim.**
- **Why Nominatim was dropped:** its usage policy treats periodic requests from an application as
  bulk geocoding. That kind of use tends to fail by silent IP blocking.
- **LocationIQ free plan** (checked 2026-11-19, third-party summaries plus the pricing page
  wording):
  - 5,000 requests/day and 2 requests/s.
  - "Limited commercial use", allowed when the app shows a "Search by LocationIQ.com" link.
  - Our volume is about 2 requests per shift.
- **Its reverse API is Nominatim-compatible** (`address.suburb/neighbourhood/city/...`), so the
  parsing logic is unchanged from round 1.
- **Alternative: Geoapify** (3,000 credits/day free, attribution required, results storable). Its
  response shape differs (`features[0].properties`). It's the fallback if LocationIQ's terms turn
  out to be unsuitable. Either way, swapping is a one-file change in the function.
- **Needs an API key.** Store it as a Supabase secret (`LOCATIONIQ_API_KEY`), never in the repo or
  the client.

**Who sees the rounded coordinate, stated honestly:**
- **Our Supabase edge function.** Coordinates go in the body. My assumption is that Supabase's
  invocation logs record method, path, status and timing but not request bodies. That's unverified
  (§9), and checked in Step 5d by reading the dev project's function logs after a test call.
- **LocationIQ.** It receives the rounded point in its request URL. Its server logs are a
  **third-party retention point this app doesn't control**, governed by LocationIQ's privacy
  policy, not "transit only". The user should accept this knowingly (Step 0).

**The label is not a privacy win over a rounded coordinate.** Repeated `start_area = "Wicker Park,
Chicago"` discloses the home neighbourhood just as a 2-decimal coordinate would, and it's *more*
readable to someone skimming. The label is chosen for **usefulness**: a Phase 2 per-area breakdown
needs human-readable labels. It doesn't make the data safer. The real privacy controls are:
- coordinates never reach our storage
- precision is capped at the neighbourhood
- area is optional and denial-safe

If the user wants less, the cheapest option is to **drop `start_area` from Start's checklist**.
Start is where home leaks, and End locations are far less identifying.

**Rejected alternative:** store a rounded 2-decimal coordinate string instead. It needs no third
party and gives equivalent disclosure, but it's useless for an area breakdown. It remains the
fallback if the user objects to LocationIQ: drop `reverse-geocode` and write `"41.88,-87.63"`.

**Retention:** labels live as long as the item, which is indefinitely. IRS records must be kept at
least 3 years after filing. Item deletion is out of scope (§10).

---

## 6. Downtime and trip chaining

Under per-ride tracking, `downtime = this start − previous end` breaks down in several ways:
- Chained, queued and pooled rides make it negative.
- The first ride of the day is measured against last night's ride.
- One missed capture poisons two values.
- Ordering is by `created_at`, not by capture time.
- The engine has no cross-item window to compute it with.

Under shifts, the time between shifts is off-duty time. Idle time *within* a shift isn't observable
from two captures, and the platform's app already reports it.

**Decision:** Phase 1 has no downtime. It reports **hours online per week** and **earnings per
week**, and their ratio is the real hourly rate. Ratio-of-sums is Phase 2. Until then, the driver
divides the two cards.

---

## 7. Implementation steps

### Step 0. Preconditions (no changes to the repo or database)

1. **The `20261119000000_add_closed_at_field.sql` migration is resolved.** It's already applied to
   dev, as verified above. Consequences:
   - `db push` will **not** re-apply or re-push it. It can't interfere with Step 4.
   - Its only open issue is that it's **untracked in git** while live on dev, which is repo/DB
     drift.
   - Recommended: ask the user to commit it as its own commit before this work starts, so this
     feature's commits stay separate. That's the user's call. This plan doesn't depend on it.
   - Before Step 4, re-run `supabase migration list --linked` to confirm nothing changed. If
     20261119000000 somehow shows as local-only, stop and ask, because it would then be pushed with
     this work.
   - Its effect on Step 6c: `closed_at` is optional, so the mechanic `closed` stage's required set
     stays empty and the new `IsClosed` rule hides closed jobs exactly as today.
2. **LocationIQ account.** The user signs up for the free plan and provides an access token. Then:
   ```bash
   supabase secrets set LOCATIONIQ_API_KEY=<token> --project-ref utwyvtbzesswpoihmlic
   ```
   The user runs this, or pastes the token for the implementer to run it. Never commit the token.
   The user also confirms they accept LocationIQ seeing rounded (~110 m) points (§5), and decides
   whether to keep `start_area` at all.
3. Ask for one or two real dashboard photos (one digital, ideally one analog) for Step 5d. Keep them
   **untracked**, like `plans/diet-workflow/test-plate.jpg`.

### Step 1. Engine migration: `supabase/migrations/20261120000000_report_engine_signed_weights_timestamps_date_key.sql`

Four generic extensions. The header comment explains each. None of them changes how an existing
config behaves, and Nutrition's report output must be byte-identical afterwards (Step 4).

**On cutting `parse: "timestamp"`.** It exists only for the "Hours online" card. Its cost is:
- one STABLE plpgsql helper (1b)
- one validation branch (1a)
- two `case` arms in `raw_segments` (1e)

I'm keeping it because hours vs. earnings is the driver's real productivity number (§6) and the
code is small. To cut it, delete 1b, the `parse` line in 1a, the two `case` arms in 1e, the `hours`,
`start_time` and `end_time` entries in the Mileage config, and check-script case 1's hours
assertion. Nothing else depends on it. This is a cheap call for the architect or user either way.

**1a. Signed weights, plus `hidden`/`parse` validation.** `create or replace` keeps the dependency
from the CHECK, because the signature is unchanged. The body is identical to 20261115010000 except
for the marked lines:

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

Negative weights change only the arithmetic of `sum(weight * value)`, which `report_series` already
does generically. Zero stays rejected. The rule that a derived field needs every component present
is unchanged, because it lives in `report_series`'s derived-term CTEs, which 1e copies verbatim.

**1b. `private.jsonb_epoch`:** a timestamp string to epoch seconds, never raising.

```sql
-- A base field with "parse": "timestamp" reads its value as epoch seconds, so a derived field can
-- subtract two timestamps (Rideshare hours online = end_time - start_time, weights +-1/3600).
-- Only ISO 8601 with an explicit offset/Z is accepted, so the result never depends on the session
-- TimeZone. Unparseable -> null -> ignored, same contract as jsonb_numeric. plpgsql for the
-- exception handler (a regex can't rule out month 13; one bad value must not abort the report).
-- STABLE, not IMMUTABLE: the text->timestamptz cast is STABLE.
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
-- "YYYY-MM-DD" is taken as-is (a receipt date is a calendar date, not an instant). An ISO
-- timestamp with offset is converted to p_tz's local date (a shift's start_time). Anything else
-- -> null, and the caller falls back to created_at. Never raises.
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

**1d. CHECK gets `item_date_key`.** Drop and re-add the constraint. The existing clauses are
unchanged:

```sql
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
```

`note` is deliberately not validated by the CHECK, the same as `item_noun`. The client ignores a
non-string `note`.

**1e. `report_series`: `create or replace`, same signature and return type.** Three CTEs change.
Every other CTE is copied **verbatim** from 20261115010000.

```sql
  base_fields as (
    select f ->> 'key' as key, f ->> 'item_agg' as item_agg, f ->> 'period_agg' as period_agg,
           f ->> 'parse' as parse                                                    -- NEW
    from cfg, jsonb_array_elements(cfg.c -> 'fields') as f
    where not (f ? 'weights')
  ),
  -- derived_terms: unchanged
  its as (
    -- CHANGED: the item's local day is its item_date_key value if configured and parseable,
    -- else created_at's local day (exactly the old behaviour when item_date_key is absent).
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

- `::timestamp` before `date_trunc` avoids the `timestamptz` overload's session-TimeZone
  dependency. The result is identical.
- `item_date_key` reads **live `item.data` only**. That's fine here: `date` is on the only Expenses
  stage, and `start_time` isn't shared. Say so in the header.
- `report_series` stays `language sql stable security invoker`.

**Rejected alternatives:**
- Store `miles` and `hours` at End capture. That breaks the derived-never-stored precedent and goes
  stale on a chat correction.
- Store epoch numbers alongside the ISO strings. That gives two sources of truth.
- Drop the expense `date`. A Dec 31 receipt logged on Jan 2 would land in the wrong tax year.

### Step 2. Content migration: `supabase/migrations/20261120010000_add_rideshare_workflows.sql`

The header summarises:
- §2 (two workflows, shift unit)
- §3 (platform log as corroboration, `platform` required)
- the key conventions (`{prefix}_odometer/_time/_area`, `*_usd`)
- the Step 1 dependency

Matching:
- The account is matched by `'Joe''s Auto Repair'`, as in Nutrition.
- Workflows are idempotent via `not exists`, because `workflows.name` isn't unique.
- Stages are idempotent via `on conflict (workflow_id, title) do nothing`, because `stages` has
  `unique (workflow_id, title)` (phase0 line 39).

```sql
insert into public.workflows (account_id, name, item_label)
select w.account_id, v.name, v.item_label
from public.workflows w
cross join (values ('Rideshare Mileage', 'shift'), ('Rideshare Expenses', 'expense')) as v(name, item_label)
where w.name = 'Joe''s Auto Repair'
  and not exists (select 1 from public.workflows x where x.name = v.name);

-- Shift: Start (initial) -> End (terminal). platform is REQUIRED on Start: it is the
-- business-purpose element of the substantiation record (see header), so Complete Stage must
-- not appear without it. The client pre-fills it from the previous shift.
insert into public.stages (workflow_id, title, sequence_order, is_initial, is_terminal, checklist, optional_checklist)
select w.id, s.title, s.seq, s.is_initial, s.is_terminal, s.checklist, s.optional
from public.workflows w
cross join (values
  ('start', 1, true,  false,
   '["start_odometer","start_time","platform","start_area"]'::jsonb,
   '["start_area"]'::jsonb),
  ('end',   2, false, true,
   '["end_odometer","end_time","end_area","tolls_usd","parking_usd","earnings_usd"]'::jsonb,
   '["end_area","tolls_usd","parking_usd","earnings_usd"]'::jsonb)
) as s(title, seq, is_initial, is_terminal, checklist, optional)
where w.name = 'Rideshare Mileage'
on conflict (workflow_id, title) do nothing;

-- Expense: one stage, both initial and terminal (a flat log). Every field optional: a missing
-- date falls back to created_at's local day; categories are mutually optional.
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
  "note": "For taxes, also download your Uber/Lyft weekly trip history and annual tax summary and keep them with this log. This log covers the miles they don''t report (driving to pickups, waiting).",
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
  "note": "Keep receipts. Gas, maintenance and insurance count only under the actual-expense method, not on top of the standard mileage rate.",
  "fields": [
    {"key": "phone_usd",       "label": "Phone (business share)",                   "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "supplies_usd",    "label": "Supplies",                                 "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "other_usd",       "label": "Other",                                    "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "gas_usd",         "label": "Gas (actual-expense method only)",         "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "maintenance_usd", "label": "Maintenance (actual-expense method only)", "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "insurance_usd",   "label": "Insurance (actual-expense method only)",   "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"}
  ]
}'::jsonb
where name = 'Rideshare Expenses' and report_config is null;
```

(The `''` inside the Mileage note is SQL escaping for the apostrophe in "don't".)

Config notes:
- **Miles and hours exist only for shifts with both captures.** An in-progress shift contributes
  none, which is correct.
- **`item_requires` is not used,** so a shift with tolls but a failed End capture still counts its
  tolls.
- **The 1/3600 weight** has under 1e-12 h of error per shift.
- **Hidden base fields** exist only so derived-field validation passes.
- **No expense "Total" card.** A derived total would be null whenever any category is missing.
  That needs a Phase 2 "missing = 0" option.

### Step 3. Dev check scripts

**`scripts/report_series_dev_check.sql`:**
- Remove the `-- negative weight` entry (lines 96–97) from the reject list, and add it as an
  **accept** assertion.
- Keep `-- zero weight`.
- Add these reject cases:
  - `"hidden": "yes"`
  - `"parse": "date"`
  - `parse` on a derived field
  - `"item_date_key": ""`
  - `"item_date_key": 5`
- Add one accept case: a config with a string `note` and a valid `item_date_key`.

**New `scripts/rideshare_report_dev_check.sql`** follows the same style: one `do $$` block that
always ends by raising, where success is a message starting `PASS`, so every write rolls back. Test
items are back-dated to the week of 2026-01-05, `America/Chicago`.

1. **Two shifts in the same week.**
   - Shift A: 48,000 → 48,123, 2026-01-05T14:00:00Z → 2026-01-05T22:30:00Z.
   - Shift B crosses local midnight, with `start_time` on 2026-01-06 local.
   - Expect `miles` and `hours` to be the sums (A's hours = 8.5), both in week 2026-01-05.
2. **An in-progress shift** (start only) counts in `item_count` but contributes no miles or hours.
3. **Malformed `end_time`** (`"yesterday"`, `"2026-13-01T00:00:00Z"`) gives no hours for that item
   and no error.
4. **Expense date bucketing.**
   - `created_at` = 2026-01-02 with `"date": "2025-12-31"` buckets to December 2025 (query spans
     both months).
   - With no parseable date, it falls back to `created_at`.
5. **Regression:** the updated `report_series_dev_check.sql` passes.

**Before Step 4**, snapshot the real Nutrition output:

```bash
supabase db query --linked "select * from public.report_series((select id from public.workflows where name = 'Nutrition Tracker'), '2026-11-01', '2026-11-30', 'America/Chicago')" > <session scratchpad>/nutrition_before.txt
```

The workflow name `Nutrition Tracker` is verified in `20261112000000` line 22. After Step 4, re-run the same query
and `diff` the two. They must be identical.

### Step 4. Push migrations to dev and verify

```bash
cd /home/mmcbride/micah/claude/workflow-app
supabase migration list --linked      # re-confirm: every local migration through 20261119000000 has a remote
supabase db push --linked --dry-run
```

**The dry run must list exactly these two files, and nothing else:**
- `20261120000000_report_engine_signed_weights_timestamps_date_key.sql`
- `20261120010000_add_rideshare_workflows.sql`

If it also lists `20261119000000_add_closed_at_field.sql`, dev's state has changed since
2026-11-19. Stop and ask the user before pushing.

```bash
supabase db push --linked
supabase db query --linked -f scripts/report_series_dev_check.sql      # expect PASS
supabase db query --linked -f scripts/rideshare_report_dev_check.sql   # expect PASS
# re-run the Nutrition snapshot query, then diff against the "before" file
```

### Step 5. Edge functions

**5a. `supabase/functions/scan-odometer/index.ts`** has the scan-plate shape: 200 / 422 for
"unreliable" / 502 for upstream failure.

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
const MAX_READING = 1_999_999;

function parseReading(raw: string): OdometerReading | null {
  let p: unknown;
  try { p = JSON.parse(raw); } catch { return null; }
  if (typeof p !== "object" || p === null) return null;
  const { reading, unit, note } = p as Record<string, unknown>;
  if (reading === null) return null;
  if (typeof reading !== "number" || !Number.isFinite(reading)) return null;
  if (reading < 0 || reading > MAX_READING) return null;
  if (Math.round(reading * 10) !== reading * 10) return null; // at most one decimal
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
```

**5b. `supabase/functions/reverse-geocode/index.ts`** uses the same CORS and bearer boilerplate.

```ts
// Coordinates in (POST body), coarse area label out (2026-11-20). The caller has already
// rounded to 3 decimals (~110 m); only the returned label is ever written to item.data.
// Never log the body or coordinates. Coordinates travel in the POST body, not our URL, so our
// own function invocation logs don't carry them. Provider: LocationIQ free plan (licensed for
// app traffic with a "Search by LocationIQ.com" link, shown in the capture UI), NOT public
// Nominatim -- its usage policy treats periodic app requests as bulk use (round-2 review).
// LocationIQ's reverse API is Nominatim-compatible, so address parsing is the standard shape.
// LocationIQ itself does see the rounded point in its request URL and may log it (third party).
const KEY = Deno.env.get("LOCATIONIQ_API_KEY");
type Body = { lat: number; lng: number };
// validate: finite numbers within -90..90 / -180..180, else 400. If !KEY -> 200 {area: null}.
const url = `https://us1.locationiq.com/v1/reverse?key=${KEY}&format=json&zoom=14` +
            `&addressdetails=1&normalizecity=1&accept-language=en` +
            `&lat=${lat.toFixed(3)}&lon=${lng.toFixed(3)}`;
const res = await fetch(url, { signal: AbortSignal.timeout(5000) });
// non-2xx (404 "Unable to geocode", 429 rate limit, 401 bad key) -> 200 {area: null}
// a = json.address; local = a.suburb ?? a.neighbourhood ?? a.city_district ?? a.quarter;
// city = a.city ?? a.town ?? a.village ?? a.county;
// area = [local, city].filter(Boolean).join(", ") || null
// 200 {area}. Exceptions (timeout, network) -> 200 {area: null}: location is best-effort.
```

`normalizecity=1` makes LocationIQ always fill `city`. The `?? town ?? village` chain stays as a
harmless fallback.

**5c. `supabase/config.toml`:** add explicit blocks after `[functions.scan-plate]`, with the same
comment reasoning:

```toml
[functions.scan-odometer]
verify_jwt = true

[functions.reverse-geocode]
verify_jwt = true
```

**5d. Check, deploy and smoke-test:**

```bash
deno check supabase/functions/scan-odometer/index.ts supabase/functions/reverse-geocode/index.ts
supabase secrets list --project-ref utwyvtbzesswpoihmlic          # LOCATIONIQ_API_KEY present (Step 0.2)
supabase functions deploy scan-odometer   --project-ref utwyvtbzesswpoihmlic --use-api
supabase functions deploy reverse-geocode --project-ref utwyvtbzesswpoihmlic --use-api
supabase functions list --project-ref utwyvtbzesswpoihmlic        # both ACTIVE, verify_jwt true
```

Smoke tests:
- **`scan-odometer`:** curl it with the user's dashboard photos and a user JWT, as in the
  scan-plate plan.
  - Expect the ODO reading, not a trip meter.
  - Send one blurred or dark photo and expect 422.
- **`reverse-geocode`:** curl it with a public landmark, **not** the user's home, and expect a
  sensible label.
- **Logging check:** open the dev project's Edge Function logs for `reverse-geocode` in the
  dashboard (Functions → reverse-geocode → Logs/Invocations). Confirm the invocation entry doesn't
  contain the request body or the coordinates. If it does, note it in §9 and tell the user. The
  design doesn't change: it would be our own project's logs, with Supabase's log retention.

Secrets: `ANTHROPIC_API_KEY` already exists. `LOCATIONIQ_API_KEY` is new (Step 0.2).

### Step 6. Web changes

**6a. `web/wwwroot/js/geolocation.js`** (new). Load it in `index.html` right after `js/timezone.js`
(line 89).

```js
// Coarse position for shift capture; resolves null on denial/timeout/unsupported, never rejects.
// Rounded here so a precise coordinate never leaves the device.
window.getApproxPosition = () => new Promise(resolve => {
  if (!navigator.geolocation) return resolve(null);
  navigator.geolocation.getCurrentPosition(
    p => resolve({ lat: Math.round(p.coords.latitude * 1000) / 1000,
                   lng: Math.round(p.coords.longitude * 1000) / 1000 }),
    () => resolve(null),
    { enableHighAccuracy: false, timeout: 6000, maximumAge: 120000 });
});
```

**6b. `web/Services/WorkflowApiClient.cs`:**
- Add `public record OdometerScanResult(double Reading, string Unit, string Note);`.
- Add `ScanOdometerAsync(base64, mediaType)`, returning `OdometerScanResult?`. It returns null on
  422 and throws otherwise, like `ScanFoodPhotoAsync`.
- Add `ReverseGeocodeAsync(double lat, double lng)`, returning `string?`. It POSTs
  `{lat, lng}` as JSON, **never throws** (it catches everything and returns null), and has a 7 s
  `CancellationTokenSource` timeout.
- `ReportField` gets `bool Hidden`. `ParseReportConfig` reads `f["hidden"]` as a bool, default
  false.
- `ReportConfig` gets `string? Note`. It's read the same way as `item_noun` at line ~102: a string,
  else null.
- `parse` and `item_date_key` stay server-only.

**6c. `WorkflowDetail.razor`, list visibility.** Replace the predicate in `VisibleItems()`
(lines 596–599). "Closed" now means: **in a terminal stage that isn't also initial, with that
stage's required fields filled.**

```csharp
private bool IsClosed(ItemSummary i) =>
    _stages!.FirstOrDefault(s => s.Id == i.StageId) is { IsTerminal: true, IsInitial: false } st
    && st.Checklist.Except(st.OptionalChecklist)
         .All(f => i.Data.TryGetPropertyValue(f, out var v) && v is not null);

private IEnumerable<ItemSummary> VisibleItems() =>
    _showClosed ? _items! : _items!.Where(i => !IsClosed(i));
```

Effect on each stage:

| Stage | Required set | Result |
|---|---|---|
| Mechanic `closed` | Only `closed_at`, which is optional (20261119000000), so empty | Hidden, same as today |
| Nutrition `dinner` | All optional, so empty | Hidden, same as today |
| Expenses `logged` | Initial stage | Never hidden. Fixes the empty list. |
| Shift `end` | `end_odometer`, `end_time` | Visible until both are captured. Fixes the vanishing shift. |

Rejected alternative: special-casing by `item_label`.

**6d. `WorkflowDetail.razor`, display-name disambiguation.** Change `ItemDisplayName`
(lines 629–633) for non-job workflows only.

**The comparison set** is `_items`: every item of this workflow, loaded by `GetItemsAsync`,
regardless of `_showClosed` or search. An item gets a ` HH:mm` suffix (local `created_at`) when
**another item in `_items` has the same current `StageId` and the same local `created_at` date.**

- Grouping is by the item's **own current stage**, not by the `stageId` argument, which can be a
  previewed stage. That way an item's name is the same in the list, the overview header and the
  stage header.
- Items in different stages already differ by stage title ("Start ..." vs "End ..."), so they
  don't need the suffix.

```csharp
private bool HasSameDaySibling(ItemSummary item)
{
    var day = item.CreatedAt.ToLocalTime().Date;
    return _items is not null && _items.Any(o => o.Id != item.Id && o.StageId == item.StageId
                                              && o.CreatedAt.ToLocalTime().Date == day);
}
// non-job branch:
// $"{StageTitle(stageId ?? item.StageId)} {item.CreatedAt.ToLocalTime():yyyy-MM-dd}"
//   + (HasSameDaySibling(item) ? $" {item.CreatedAt.ToLocalTime():HH:mm}" : "")
```

This is computed per call. That's O(n) per name, and O(n²) per list render at hundreds of items,
which is negligible. It's simpler than keeping a precomputed set in sync across the six places
`_items` is reassigned.

Results:
- Two expenses on 2026-11-19 read "Logged 2026-11-19 09:12" and "Logged 2026-11-19 14:05". A lone
  one stays "Logged 2026-11-19".
- Nutrition (one item per day) is unchanged.

Scope: the set is all *loaded* items, which is all items up to PostgREST's 1000-row cap. Past that,
a collision with an unloaded item isn't detected, which is acceptable for personal-scale use.

**6e. `WorkflowDetail.razor`, `_usd` prefix rendering.** Four edits, all in this file.

1. **The table** (line 697). Add a prefix flag and the `_usd` entry:
   ```csharp
   private static readonly (string Suffix, string Unit, bool Prefix)[] FieldUnitSuffixes =
       [("_g", "g", false), ("_lbs", "lbs", false), ("_usd", "$", true)];
   ```
2. **`FieldLabelAndUnit`** (lines 699–707) returns `(string Label, string Unit, bool Prefix)`. The
   fallback is `(ChecklistLabel(field), "", false)`.
3. **New helper** for the money format. `FieldText` alone would turn `12.5` into `"12.5"`, not
   `"12.50"`:
   ```csharp
   private static string UnitValueText(string field, JsonNode? v, string unit) =>
       unit == "$" && v is JsonValue jv && jv.TryGetValue<double>(out var d)
           ? d.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture)
           : FieldText(field, v);
   ```
   Agent-written numeric strings (`"12.5"`) fall through to `FieldText` and show as `$12.5`. That's
   acceptable, and it matches how `_g` values display today.
4. **The call site** (lines 81 and 89–92). This is the edit round 1 left out:
   ```razor
   var (baseLabel, unit, unitPrefix) = FieldLabelAndUnit(field);
   ...
   else if (unit.Length > 0)
   {
       @(unitPrefix
           ? $"{unit}{UnitValueText(field, v, unit)} {baseLabel}{star}"
           : $"{UnitValueText(field, v, unit)}{unit} {baseLabel}{star}")
   }
   ```

Result: `tolls_usd = 12.5` shows as **`☑ $12.50 Tolls`**, and an unfilled field shows `☐ Tolls`.
`protein_g = 43` still shows `43g Protein *`: `UnitValueText` falls through to `FieldText` for
non-`$` units, so it's byte-identical.

The job-overview "Details" list (line 328) is untouched. It keeps showing `Tolls usd: 12.5`, which
is consistent with how it shows `Protein g: 43` today.

**6f. `WorkflowDetail.razor`, odometer capture block.**

**Gating** follows the Scan VIN pattern at line 101. The block renders when all of these hold:
- `_selectedStageId == _selectedItem.StageId`
- the current stage's checklist contains a key ending `_odometer`
- `prefix` = that key minus `_odometer`

`{prefix}_time`, `{prefix}_area` and `platform` are written only if they're on that stage's
checklist. That makes it a convention, not a Shift-specific hardcode.

**UI:**

```
[ Scan odometer ]   or type reading: [______] [Save]
Platform: [Uber______] [Save]                      <- only if the stage checklist has "platform"
hint: "Ignition on so the odometer is lit; photograph the ODO number, not a trip meter."
tip:  "For taxes, also download your Uber/Lyft weekly trip history and annual tax summary and
       keep them with this log. This log covers the miles they don't report (driving to
       pickups, waiting)."
(after a capture)  Odometer 48,213.0 -- Correct reading: [______] [Fix]
(warnings/errors line, same styling as _vinScanError)
small: "Area names: Search by LocationIQ.com" (a link to https://locationiq.com; the free plan's
       attribution requirement)
```

**Platform pre-fill.** This satisfies the required business-purpose field without extra taps.
- When the block first renders for an item that lacks `platform`, `_platformInput` is set to the
  `platform` of the most recent *other* item in `_items` that has one (by `CreatedAt` desc).
  Otherwise it's empty.
- The value is written as part of the first capture's patch (step 5 below).
- The Platform [Save] writes only `platform`, for changing it later or for a first-ever shift.
- If the box is empty at capture time, the patch omits `platform`. The checklist then shows
  `☐ Platform *`, and Complete Stage stays hidden until it's filled, either here or by chat.

**Flow for `CaptureAsync(prefix, double reading, string source, string? modelNote)`:**

1. **Capture time.** Take `capturedAt` when the photo is selected (in `OnChange`) or when typed
   Save is tapped. Format it as
   `DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)`.
2. **Start the area lookup.** At that same moment, if `{prefix}_area` is on the checklist and not
   yet set, start `var areaTask = GetAreaAsync();`. That's JS `getApproxPosition`, then
   `ReverseGeocodeAsync`. It never throws, and returns null on any failure. In the photo path it
   runs **concurrently** with the scan.
3. **Scan** (photo path only). Resize with `RequestImageFileAsync("image/jpeg", 1600, 1600)`, then
   call `ScanOdometerAsync`.
   - null → "Couldn't read the odometer -- try again, or type the reading."
   - `Unit == "km"` → "Odometer appears to be in km -- switch the display to miles or type the
     reading in miles."
   - Either error ends the flow. Nothing is written, and `areaTask` is abandoned. It's harmless,
     since it writes nothing itself.
4. **Plausibility.** Purely client-side over already-loaded data. No new RPC.
   - **(i) End vs. Start:** for `prefix == "end"`, compare against this item's
     `_selectedItem.Data["start_odometer"]`.
     - lower → block
     - more than 1,000 above → block unless typed
   - **(ii) Start vs. the previous shift:** for `prefix == "start"`, the source is `_items`.
     `GetItemsAsync` loads every item of the workflow in every stage, so closed shifts are present
     even though `VisibleItems()` hides them from the list.
     - Take the other items (`Id != _selectedItem.Id`) with a numeric `end_odometer`.
     - Choose the one with the greatest `end_time`, parsed as `DateTimeOffset`; if unparseable,
       use the greatest `CreatedAt`.
     - If the new reading is below its `end_odometer`, warn and save. The message names both
       numbers.
   - **Block** shows the message and puts the value in the typed box for one-tap override.
     **Warn** saves and shows the message.
5. **Wait for the area, with a deadline.** The patch build **does** await the area task, but only
   up to a deadline:
   ```csharp
   string? area = null;
   if (areaTask is not null)
   {
       var remaining = TimeSpan.FromSeconds(8) - (DateTimeOffset.UtcNow - captureStartedAt);
       if (remaining > TimeSpan.Zero &&
           await Task.WhenAny(areaTask, Task.Delay(remaining)) == areaTask)
           area = await areaTask;
   }
   ```
   The budget is 8 s from the moment of capture: geolocation timeout 6 s, plus geocode, which
   usually finishes in under 1 s. In the photo path the scan normally takes longer than that, so
   there's usually no extra wait.

   If the deadline passes, the capture is written **without** area. There's no late second patch.

   Rejected: a fire-and-forget second `UpdateDataAsync` when the area arrives. It would make two
   `item.data_changed` events per capture, race with a "Fix", and could land after the user has
   moved stages. One write per capture keeps the audit trail clean.
6. **Build the patch:**
   - `{prefix}_odometer` always.
   - `{prefix}_time` only if not already set, so a re-scan doesn't move the shift start.
   - `{prefix}_area` only if not already set **and** `area` is non-null.
   - `platform` only if it's on the checklist, not already set, and `_platformInput` isn't empty.
7. **Write.** Call `UpdateDataAsync`, then
   `AddNoteAsync(item, $"{Prefix} odometer {reading:N1} mi ({source}){modelNote}", _selectedStageId)`.
8. **Reload** items and notes, with the same tail as `OnVinPhotoSelected`.

**"Fix"** writes only `{prefix}_odometer`, plus the note `"Corrected {prefix} odometer {old} -> {new}"`.

**Stage advance stays manual** via Complete Stage. On Start it appears once `start_odometer`,
`start_time` and `platform` are present. Auto-advance was rejected: a stray tap on the then-visible
End scan would end a shift seconds after it started.

**6g. `web/Pages/WorkflowReport.razor`:**
- Change the loop to `@foreach (var field in report.Fields.Where(f => !f.Hidden))`.
- If `report.Note` is non-null, render it once above the cards as a muted paragraph, styled like
  existing secondary text.
- `mi` and `h` already format via the default branch.

**6h. Build:** run `dotnet build web/`, then a local run for a UI sanity pass. Deploying (a push to
`main`) happens only when the user asks to commit and push.

### Step 7. Live checks on a phone (dev site)

1. **Expenses:**
   - "+ New Expense", then chat "$42.10 gas yesterday". The item stays in the list, and the
     checklist shows `$42.10 Gas`.
   - Add a second expense the same day. Both list names gain `HH:mm`.
   - Report shows the month card at $42.10, the expenses note at the top, and no Total card.
   - An expense dated last month lands in last month.
2. **Shift:**
   - "+ New Shift". Platform is pre-filled after the first ever shift; empty on the very first.
   - Scan at the car. The location prompt appears, then the reading, time and area. The
     LocationIQ link and the tax tip are visible.
   - With platform empty, Complete Stage is hidden. Fill it, and Complete Stage appears.
   - On End, scan. A deliberately lower typed reading is blocked.
   - Add tolls via chat. They show as `$x.xx Tolls`.
   - The Report week shows miles, hours and tolls matching hand arithmetic, plus the note.
   - The shift leaves the list only after End's capture.
3. Deny location once. The capture still saves, with no area.
4. Nutrition report, Nutrition checklist (`43g Protein`) and the mechanic Jobs list are all
   unchanged.

---

## 8. Risks, edge cases, rollback

- **Engine regression on Nutrition.** Mitigations: the untouched CTEs are copied verbatim, the dev
  check is updated, and the real Nutrition output is diffed before and after.
- **A CHECK re-add failing.** It can only fail on clauses already enforced today. If it fails, the
  migration transaction rolls back.
- **Clock skew.** `{prefix}_time` comes from the phone's clock. `item_events.created_at` is the
  server-side corroboration.
- **Shifts crossing midnight or a week boundary** belong to their start date or week. That's
  intended.
- **Negative miles from a bad chat correction.** The client checks cover only the capture path.
  Accepted, and noted in the header.
- **Plausible single-digit misreads** (§4). Accepted, with the mitigations listed there.
- **The agent picks the wrong `*_usd` key from chat.** It sees stage checklists in its prompt. A
  prompt hint is a later tweak if needed.
- **LocationIQ changes its free-plan terms, rate-limits, or the key is revoked.** Area becomes null
  and capture is unaffected. The Geoapify swap is a one-file change.
- **Platform pre-fill copies a stale value** (a driver switches from Uber to Lyft). The value is
  visible and editable before capture, and in the checklist after. Accepted.

**Rollback, in this order.** Content goes before the engine, because the engine rollback needs no
config to use the new keys.

1. **Web:** revert the commit(s) and push to `main`.
2. **Functions:**
   ```bash
   supabase functions delete scan-odometer   --project-ref utwyvtbzesswpoihmlic
   supabase functions delete reverse-geocode --project-ref utwyvtbzesswpoihmlic
   supabase secrets unset LOCATIONIQ_API_KEY --project-ref utwyvtbzesswpoihmlic
   ```
   Also remove the two `config.toml` blocks.
3. **Content.** Save the following as `scripts/rideshare_content_rollback.sql` and run it with
   `supabase db query --linked -f scripts/rideshare_content_rollback.sql`.
   - The CLI role bypasses RLS. The append-only tables have no DELETE *policy* but no trigger, so
     the deletes succeed.
   - Delete order follows the foreign keys.
   - It's matched by name only. These names exist only in this plan's migration.
   ```sql
   begin;
   create temp table rb_wf on commit drop as
     select id from public.workflows where name in ('Rideshare Mileage', 'Rideshare Expenses');
   -- guard: exactly the two expected workflows, or abort
   do $$ begin
     if (select count(*) from rb_wf) <> 2 then
       raise exception 'expected 2 rideshare workflows, found %', (select count(*) from rb_wf);
     end if;
   end $$;
   delete from public.chat_messages where workflow_id in (select id from rb_wf);
   delete from public.agent_events  where workflow_id in (select id from rb_wf);
   delete from public.item_events
     where item_id in (select id from public.items where workflow_id in (select id from rb_wf));
   delete from public.items         where workflow_id in (select id from rb_wf);
   delete from public.stages        where workflow_id in (select id from rb_wf);
   delete from public.workflows     where id in (select id from rb_wf);
   commit;
   ```
   Then delete `20261120010000_add_rideshare_workflows.sql` from the repo and remove its row from
   the migration history:
   ```bash
   supabase migration repair --status reverted 20261120010000 --linked
   ```
   Otherwise the next push would re-apply it.

   Before running this: once real driver data exists, this deletes tax records. Ask the user, and
   offer a CSV export of `items.data` for the two workflows first:
   ```bash
   supabase db query --linked "select ... " > file
   ```
4. **Engine.** Use a new forward migration, `2026112X..._revert_report_engine_extensions.sql`, that:
   - re-issues the 20261115010000 definitions of `report_fields_valid` and `report_series`
     verbatim
   - drops and re-adds the original `workflows_report_config_shape` CHECK
   - drops `private.jsonb_epoch(jsonb)` and `private.item_local_date(jsonb, text)`

   Re-adding the CHECK validates the remaining rows, so it fails loudly if any config still uses
   `item_date_key`. That's the intended guard. Also revert the `report_series_dev_check.sql` edit.

---

## 9. Assumptions I couldn't verify

1. **The aggregation rule is in §1.274-5T(c)(6)(i)(C).** That's where the sanity-check places the
   uninterrupted-business-use / single-record language. The CFR cross-reference I found labels (B)
   and (C) as the aggregation rules for expenditures and for business use respectively. I haven't
   read the current eCFR paragraph text. Confirm on eCFR before the citation goes into the
   migration header.

   Separately, whether a shift log **plus** platform trip history meets §274(d) is a judgment for a
   tax professional. The plan's position is that it's much stronger than either alone (§3).
2. **The case-law characterisation** (*Brown* rejected, *Ressen* accepted on corroboration) comes
   from the sanity-check. I didn't read the opinions.
3. **Home-to-first-pickup miles** with the app on are contested as business vs. commuting. The
   shift boundary is wherever the driver taps Start.
4. **LocationIQ's free-plan terms** (5,000/day, 2 req/s, commercial use allowed with a "Search by
   LocationIQ.com" link) are taken from the pricing page wording and third-party summaries. Re-read
   https://locationiq.com/pricing and its terms at Step 0.2.
5. **Supabase function logs** don't capture POST bodies. Checked empirically in Step 5d.
6. **iOS Safari** shows the geolocation prompt for a `getCurrentPosition` call made right after an
   `InputFile` change event. If it doesn't, call `getApproxPosition` from a pointerdown on the Scan
   label instead.
7. **`claude-sonnet-5-5` reliably tells ODO from trip meters** on the user's cluster. Step 5d's
   smoke test checks this.
8. **The standard mileage rate is deliberately not used** anywhere.

---

## 10. Out of scope (deliberately)

- **Phase 2 engine features:**
  - group-by (per-area, per-category)
  - ratio-of-sums (earnings per hour)
  - a cross-item window (personal miles between shifts, downtime, a history-based plausibility
    check)
  - derived "missing = 0" (an expense Total)
  - a per-workflow period switcher
- **Annual business-use % and the Schedule C line 44 split.** These need Jan 1 / Dec 31 readings
  plus the cross-item gap.
- **Multi-vehicle support.**
- **Storing odometer photos as evidence.** Not rejected, deferred. Unlike VIN/plate scans, the
  photo has real evidentiary value here. A private Storage bucket with an opt-in "keep photo"
  toggle is a reasonable Phase 1.5. It needs its own retention and privacy decision, because
  dashboard photos can show location and time. The audit trail and correction notes are the Phase 1
  substitute.
- **Importing platform trip history, or a CSV/PDF tax export, as engineering.** Phase 1 covers the
  corroboration need with the reminder (§3). Ingesting the files is later work.
- **Item deletion and retention controls.**
- **Any mileage-rate deduction estimate.**
- **Prod.** Nothing is ported. This joins the dev-only list in `PROGRESS.md` at the next milestone.

---

## Feedback from this round

### Plan-reviewer (`round-1-review-notes.md`)

1. **Step 6e never changed the real call site (blocking).** *Adopted.*
   - Verified: line 81 destructures `(baseLabel, unit)`, and line 91 hardcodes
     `{FieldText}{unit}`.
   - Step 6e now specifies all four edits: the table, the return type, a new `UnitValueText` for
     `0.00` money formatting, and the call-site branch.
   - Round 1's "$12.50" also silently assumed two-decimal formatting that `FieldText` doesn't do.
     Now fixed and stated.
2. **Step 0's untracked migration was left unresolved (blocking).** *Adopted, resolved by fact.*
   - A read-only `supabase migration list --linked` shows 20261119000000 is **already applied to
     dev**. It's only untracked in git.
   - Step 0 now says so. Step 4 states the exact expected dry-run output (only the two new files)
     and the stop condition if 20261119000000 appears.
3. **Steps 6d and 6f underspecified; stages constraint unverified (blocking).** *Adopted.*
   - **6d:** the comparison is over all of `_items`, grouped by the item's own current
     `StageId` + local `created_at` date, computed per call. Code is given.
   - **6f:** the patch build awaits the area task with an 8 s deadline from capture, and there's no
     second write; the rejected alternative is stated. Plausibility check (ii) reads the
     already-loaded `_items`. `GetItemsAsync` loads all stages, so closed shifts are present
     despite `VisibleItems()`. No new RPC.
   - **Stages:** `unique (workflow_id, title)` verified at phase0 line 39, and cited in §1 and
     Step 2.
4. **The content rollback had no SQL.** *Adopted.* Full SQL with a count guard, FK-ordered deletes
   (including `chat_messages` and `agent_events`, which round 1 missed), `migration repair`, and a
   data-loss warning. The engine rollback is also made concrete.
5. **Reviewer issue 4** (a pointer on derived-field null semantics). *Adopted.* One sentence after
   1a.

### Sanity-check (`round-1-sanity-check.md`)

1. **Wrong citation, weak substantiation story (blocking).** *Adopted.*
   - The citation is now (c)(6)(i)(C). I'm only moderately confident of the paragraph letter from my
     own search, so §9.1 says to confirm it on eCFR before it goes into the migration header.
   - §3 is reframed: the app log is half the record, and the platform trip history is the
     corroboration.
   - Phase 1 adds the reminder in two places: a static tip in the capture block, and a
     config-driven `note` on both Report pages. Round 1 had excluded the reminder; it's now in
     Phase 1. *Ingesting* those files stays out of scope.
2. **`platform` was optional (blocking).** *Adopted, both suggested fixes combined.* It's required on
   Start and pre-filled from the previous shift, so it's required without per-shift friction.
3. **Nominatim unsuitable for app traffic (blocking).** *Adopted.*
   - Switched to LocationIQ, chosen over Geoapify because its reverse API is Nominatim-compatible,
     so the parsing is unchanged. Geoapify is the named fallback.
   - Added: the API-key secret setup, the attribution link, coordinates in the POST body, the
     non-2xx handling, and the rollback `secrets unset`.
   - Also adopted the logging points: the third-party retention is now stated plainly, and there's
     an empirical check of Supabase invocation logs.
4. **`parse: "timestamp"` cost/benefit.** *Partly adopted.* Kept, but the cost and the exact
   clean-cut recipe are now stated in Step 1, so the architect or user can drop it cheaply. I didn't
   cut it: it's small, it's isolated, and hours online is the denominator of the driver's real
   productivity number.
5. **Single-digit misreads clear the bounds checks.** *Adopted as a documented residual risk* (§4,
   §8), with a Phase 2 history-based check named.
6. **Odometer photo as evidence.** *Partly adopted.* Reframed from "out of scope" to "deferred
   Phase 1.5 opt-in", with the reason it differs from VIN/plate. It isn't built now because it needs
   its own retention and privacy decision.
7. **Area labels aren't more private than rounded coordinates.** *Adopted.* §5 now says the label is
   chosen for usefulness, not privacy, and offers dropping `start_area` as the real privacy lever
   (Step 0.2 asks).
8. **Citation fix.** Same as item 1.
9. **The "supplies" boundary.** *Adopted* as a one-line caveat in §3.
10. **6d covers only loaded items.** *Adopted* as a stated scope note. In practice "loaded" means all
    items up to the 1000-row cap, since `GetItemsAsync` doesn't page.
