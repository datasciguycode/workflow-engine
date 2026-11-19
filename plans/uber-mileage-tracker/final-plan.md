# Rideshare mileage + expense tracking: final plan

Status: **final (architect review, 2026-11-19)**. Verdict: **approved-with-changes** (see the
end). Supersedes `round-2-draft.md`. Dev only (`workflow-engine-test`, ref
`utwyvtbzesswpoihmlic`). Nothing here touches `/home/mmcbride/micah/claude/workflow-app-prod`.
Nothing has been executed. The only commands run while finalising were read-only
(`supabase migration list --linked`, and one `select` over dev's terminal stages).

Not tax advice. The tax points below explain why the data model collects what it collects. They
don't replace a tax professional.

---

## Before implementation starts: what the user needs to decide or know

1. **Location tracking replaced with manual address entry (post-approval change, 2026-11-19).**
   GPS, reverse-geocoding and LocationIQ are dropped entirely. `start_address`/`end_address` are
   plain optional text fields the driver fills in by hand (e.g. pasted from the Uber/Lyft driver
   app) -- rendered by the app's existing generic checklist editor, so there's no new JS, no new
   edge function, and no third-party API key. See the addendum at the end of this file for the
   full rationale and the exact edits this replaces.
2. **The Jobs-list "closed" rule changes for one mechanic stage (Step 6b).** "Hidden by default"
   becomes "in a terminal, non-initial stage **with its required fields filled**". For
   `payment_receipt_submitted`, that means a job missing `payment_method` will now **show** in the
   default Jobs list instead of hiding. Dev currently has 0 items in that stage, so nothing visibly
   changes today. Raise this before coding, per the user's "propose before implementing" preference.
3. **The chat agent currently doesn't know today's date.** Expenses are logged by chat ("$42.10 gas
   yesterday"), and the report buckets expenses by their `date` field. So this plan adds a small
   generic change to `agent-loop`: the client sends its local date and the system prompt states it
   (Step 5d). That redeploys `agent-loop`, which every workflow's chat uses.
4. **Commit `20261119000000_add_closed_at_field.sql` first, as its own commit.** It's already
   applied to dev (re-verified 2026-11-19) but untracked in git. This work doesn't depend on it.

---

## 0. Summary of the design

The user's discussed design:
- **Ride:** a Start and End odometer photo per ride, with location and time, plus derived miles,
  downtime and area productivity.
- **Expenses:** a single-stage log with category, amount and date.

Load-bearing changes from that design:

1. **The tracking unit is a *shift* (app on to app off), not a ride** (§2). Per-ride spans miss the
   miles driven while waiting and heading to a pickup. They also suffer ±1 mi odometer error on short
   rides, double-count stacked trips, and need dashboard photos with a passenger aboard. Stages,
   fields and capture UI are the same either way, so reversing this is cheap.
2. **This app's shift log is half the tax record** (§3). The platform's trip history and annual tax
   summary are the corroboration. The UI reminds the driver to keep them, in the capture block and
   on the Report page.
3. **`platform` (the business purpose) is required on Start**, and pre-filled from the last shift.
4. **Four small, generic report-engine extensions** (Step 1): signed weights, `hidden` fields,
   `parse: "timestamp"` base fields, and a top-level `item_date_key`. Downtime, earnings-per-hour and
   the per-area breakdown are Phase 2.
5. **Expense categories are one amount key each** (`gas_usd`, `phone_usd`, ...), grouped around the
   standard-vs-actual mileage rule.
6. **No GPS or third-party geocoding.** `start_address`/`end_address` are plain optional text
   fields -- typed or pasted from the Uber/Lyft driver app -- with no coordinates collected and no
   external service involved (see the addendum).
7. **The odometer scan always has a manual path**, a correction input and plausibility checks.
   Every write is audited by `item_events`.
8. **The agent learns today's date** (Step 5d), so relative dates in chat resolve correctly.

---

## 1. Codebase facts this plan relies on (verified against the files, 2026-11-19)

- **Report engine** (`20261115010000_add_workflow_report_config.sql`):
  - `report_fields_valid` rejects any weight `<= 0`.
  - A derived field's weights must name base fields in `fields`.
  - A derived field has a per-item value only when **every** component is non-null (the
    `item_terms` CTE).
  - `report_series` buckets by `items.created_at` in `p_tz`. It reads values via
    `private.jsonb_numeric`, which accepts numbers and numeric strings only.
  - `period` is one of `day|week|month`.
  - The CHECK validates only the keys it names. Extra top-level keys such as `item_noun` pass
    untouched.
- **`scripts/report_series_dev_check.sql`:**
  - Lines 94–97 have `-- zero weight` and `-- negative weight` in the reject list.
  - Line 118 asserts the reject count: `if v_rej <> 33`.
  - It switches to the real owner as `authenticated` before calling `report_series`, so private
    helper grants are exercised.
- **Scripts run against dev** with `supabase db query --linked -f <file>`. There's no psql.
- **`web/Services/WorkflowApiClient.cs`:**
  - `ReportField(Key, Label, Unit, UnitPrefix, ItemAgg, PeriodAgg, Weights)` is at line 9.
  - `ReportConfig(Period, ItemNoun, Fields)` is at line 11.
  - The only constructor calls are line 139 (`new ReportField`) and line 144 (`new ReportConfig`).
  - `item_noun` is parsed at line ~102.
  - `GetItemsAsync` (line 207) loads every item in the workflow, in all stages, with no paging. It's
    capped only by PostgREST `max-rows` (1000).
  - `ScanFoodPhotoAsync` returns null on 422 and throws otherwise.
  - `SendAgentMessageAsync` (line 404) builds the agent-loop body.
- **`web/Pages/WorkflowDetail.razor`:**
  - **Line 81:** `var (baseLabel, unit) = FieldLabelAndUnit(field);`.
  - **Line 91:** `@($"{FieldText(field, v)}{unit} {baseLabel}{star}")`.
  - **Lines 101–124:** Scan VIN, gated on `_selectedStageId == _selectedItem.StageId &&
    checklist.Contains("vin")`.
  - **Lines 551–568:** `FieldText` formats any date-ish key (`date`, `time`, `_at`) as
    `"MMMM d, yyyy, h:mm tt"`. A plain `"2025-12-31"` would show as "December 31, 2025, 12:00 AM".
  - **Lines 596–599:** `VisibleItems()` hides every item in an `IsTerminal` stage unless
    `_showClosed`.
  - **Lines 629–633:** `ItemDisplayName`.
  - **Lines 697–707:** `FieldUnitSuffixes` and `FieldLabelAndUnit`.
  - **Lines 780–793:** `DoneNextStage` (Complete Stage) appears only on the current stage, once every
    `checklist − optional_checklist` key is non-null.
  - **Lines 824–860:** `OnVinPhotoSelected` is the pattern for resize, scan, write and reload.
  - Non-job list rows and search rows use `ItemDisplayName`. `ItemTitle` is job-only, apart from
    the agent's `selectedItemLabel`.
- **`web/Pages/WorkflowReport.razor`:**
  - The page renders, in order: the header, the `<h1>`, the period stepper `div`, and the
    `@foreach (var field in report.Fields)` cards.
  - `ValueText` formats `$` as N0/N2, and anything else as `0.#` (so `h` and `mi` are fine).
- **Terminal stages on dev today** (queried 2026-11-19):

  | Stage | Required set | Items |
  |---|---|---|
  | Joe's `closed` | empty (`closed_at` is optional) | 1 |
  | Joe's `payment_receipt_submitted` | `payment_method` | 0 |
  | Nutrition `dinner` | empty | 1 |
  | Feature Pipeline `deploy` | null checklist, parsed as `[]` | 0 |

- **`move_stage`** saves and restores only keys **shared** between the departing and arriving
  stages. Shift's `start_*` / `end_*` / `platform` keys aren't shared, so they stay live in
  `item.data`.
- **`update_data`** is a top-level merge, where `null` deletes a key. Every call writes an
  `item.data_changed` event.
- **Uniqueness:**
  - `stages` has `unique (workflow_id, title)` (phase0 line 39).
  - `workflows.name` isn't unique, so this plan uses `where not exists` for workflows.
- **Tables referencing workflows/stages/items:** `stages`, `items`, `item_events`, `chat_messages`
  (`workflow_id NOT NULL`) and `agent_events` (`workflow_id NOT NULL`). They're append-only by RLS
  only, with no triggers.
- **Edge functions:**
  - `scan-plate/index.ts` (220 lines) is the template for a 200/422/502 one-shot vision function:
    `npm:@anthropic-ai/sdk@0.32.1`, `MODEL = "claude-sonnet-5-5"`, CORS + bearer checks, and the
    photo is never stored.
  - `config.toml` has `[functions.scan-plate] verify_jwt = true`, with its reason.
- **`agent-loop/index.ts`'s system prompt has no current date or timezone.** It's built per request
  in `systemPrompt(...)` at ~line 271.
- **Deploy conventions:**
  - Functions: `supabase functions deploy <name> --project-ref utwyvtbzesswpoihmlic --use-api`.
  - Migrations: `supabase db push --linked --dry-run`, then `supabase db push --linked`.
  - Web: a push to `main` deploys to Pages.
  - Content migrations match by name/title.
- **`index.html` line 89** loads `js/timezone.js`.
- **`20261119000000_add_closed_at_field.sql`** is applied to dev (`local = remote`, re-checked
  2026-11-19). It's untracked in git.

---

## 2. Decision D1: shift vs. ride, and why two workflows

| Concern | Per-ride | Per-shift (chosen) |
|---|---|---|
| Deductible miles captured | Passenger-on-board miles only | All app-on miles, including deadhead and waiting |
| Odometer resolution | ±1 mi on a 2–5 mi ride | ±1 mi on ~100 mi, negligible |
| Stacked/queued rides | Overlapping spans double-count | One span |
| Practicality/safety | 2 photos × 15–25 rides, passenger aboard | 2 photos a day, parked |
| IRS substantiation | Still needs platform corroboration | Treas. Reg. §1.274-5T(c)(6)(i)(C), "Aggregation of business use": "uninterrupted business use, may be accounted for by a single record". A shift record has the date, odometers, miles and purpose (`platform`). Platform trip history corroborates it (§3). |

Cost of reversing: `item_label`, the workflow name and `item_noun`.

**Two workflows, not one:**
- Expenses aren't tied to the shift lifecycle.
- The engine allows one `report_config`/`period` per workflow. Mileage is weekly (pay weeks) and
  Expenses is monthly (bills).
- Tolls and parking stay on the shift. Expenses has no tolls/parking category, so nothing is
  double-logged.

---

## 3. Tax substantiation: what this app proves, and what it doesn't

**Per business use** (Pub 463 ch. 5 / §274(d)), the record needs:
- the amount (miles)
- the date
- the business purpose

It must be made at or near the time.

**Per year** (Schedule C Part IV / Form 4562 Part V), the record needs:
- total miles, split into business, commuting and other
- whether written evidence exists

**How the case law changes the framing** (summarised by the round-1 sanity check; the opinions
weren't read directly):
- In *Brown*, a bare start/stop odometer log was rejected for lack of corroboration.
- In *Ressen*, periodic entries were accepted, on corroborated detail.

**What Uber's own tax summary actually covers (corrected 2026-11-19; the original draft overstated
the gap).** Uber's help pages state that the "online miles" figure on the tax summary already
includes miles driven while waiting for a request and while en route to a pickup, not just
on-trip miles — so the platform summary is broader than this plan first assumed. Several
third-party mileage-tracking vendors (Everlance, Keeper Tax) claim Uber's figure still
under-counts real deductible miles by a wide margin, but they sell competing tracking products, so
that claim is weighted lower than Uber's own documentation. What's **not disputed by any source**:
miles driven with the app fully offline — repositioning to a busier area before going online,
driving home after the last drop-off — never appear on Uber's summary.

What follows from that:
- **This app's shift log is not primarily about catching miles Uber misses.** If a shift is
  started only once the driver goes online, there's substantial overlap with what Uber's own
  summary already reports.
- **Its real value is twofold:** (1) a contemporaneous, independently-timestamped backup record —
  case law (*Brown*) shows a bare log is weak *alone*, but a log that corroborates the platform's
  own figures is stronger than either record by itself, even when the totals roughly agree; and
  (2) if the driver chooses to start their shift *before* going online (e.g. when leaving home to
  reposition toward a busier area), it captures real business miles Uber's summary genuinely never
  sees, by any account.
- **The platform's trip history and annual tax summary remain the recommended second record** —
  not because this app's log is incomplete without it, but because two independent, consistent
  records are stronger evidence than one, and Uber's own total is still a plausible floor on
  deductible miles per the vendor sources above.

**Phase 1 surfaces this in two places**, with corrected wording:
- A static tip in the capture block: *"For taxes, also download your Uber/Lyft trip history and
  annual tax summary and keep them with this log — two consistent records are stronger evidence
  than one. If you start this shift before going online (e.g. driving to a busier area), this log
  also covers miles the platform summary doesn't count at all."*
- A `note` key in each workflow's `report_config`, shown on the Report page. Mileage uses the same
  text. Expenses uses: *"Keep receipts. Gas, maintenance and insurance count only under the
  actual-expense method, not on top of the standard mileage rate."*

| Requirement | This plan |
|---|---|
| Date | `start_time` (auto), also the report's `item_date_key` |
| Business miles | Derived `end_odometer − start_odometer`, never stored |
| Business purpose | Required `platform` on Start, pre-filled from the last shift. Complete Stage can't appear without it. |
| Destinations | In the platform trip history |
| Contemporaneous | A tap at the moment. `item_events` records actor and server time for every write. |
| Annual total miles | Not in Phase 1 (§10) |
| Fares | `earnings_usd`, optional, for analytics only |
| Tolls/parking | `tolls_usd`, `parking_usd`, optional on End. Deductible on top of the standard rate. |

**Expense categories:**
- Alongside mileage: `phone_usd` (business share), `supplies_usd`, `other_usd`.
- Actual-expense method only (tracked for comparison): `gas_usd`, `maintenance_usd`,
  `insurance_usd`.
- Caveat: a costlier or permanently installed item, such as a wired-in dashcam, may be a
  depreciable asset rather than a supply. A tax professional decides that.
- There's no mileage-rate "deduction estimate" card, because the rate changes yearly and would go
  stale in config.

---

## 4. Odometer-from-photo: risks and fallback

Failure modes:
1. **Wrong number** (trip A/B, range, speed). The prompt targets ODO and must return null when it's
   unsure.
2. **Analog tenths drum.** The prompt asks for tenths as a decimal, and plausibility checks catch a
   10× jump.
3. **Glare, night, blur.** These give null or a digit misread.
4. **km.** The function returns `unit`, and the client rejects `km` with a message.
5. **Digital clusters are lit only with the ignition on.** The UI hint says so.

**A manual path is mandatory.**
- [Scan odometer] **and** "or type reading: [___] [Save]" are always both shown.
- After a capture, "Correct reading" rewrites only `{prefix}_odometer` and adds a note.
- Every capture adds a note with its source and the model's note.

**Plausibility checks:**

| Case | Result |
|---|---|
| End below Start | Blocked |
| End − Start over 1,000 | Blocked. The typed path accepts it after re-entry. |
| Start below the previous shift's End | Saves, with a warning naming both numbers |

**Residual risk, accepted:** a plausible single-digit misread (48,213 → 48,813) clears every check.
Mitigations:
- The reading is shown prominently, next to the Correct input.
- The model's note flags digits it was unsure of.
- The driver can cross-check the week against the platform's online miles.

A history-based check is Phase 2.

---

## 5. Address fields (replaces GPS/reverse-geocoding — see addendum)

**Design:** `start_address`/`end_address` are plain, optional, free-text checklist fields —
exactly like `platform` or any other text field in this engine, with no special capture code.
The driver types or pastes an address (the tip text suggests copying it straight from the
Uber/Lyft driver app's trip screen, which also reinforces the trip-history corroboration story in
§3). There's no coordinate capture, no rounding, no third-party geocoding call, and no new secret
or edge function.

**Privacy:** no location data is ever collected in any form — not raw, not rounded, not
reverse-geocoded. Whatever the driver chooses to type is exactly what's stored, same as any other
text field, and they can leave it blank.

**Retention:** addresses live as long as the item, same as every other field. IRS records must be
kept at least 3 years after filing. Item deletion is out of scope (§10).

**Future option, not Phase 1:** if a Phase 2 per-area productivity breakdown is ever built, it can
work off this same free-text field (e.g. a rough city/neighborhood parse or just grouping by exact
string match) without needing to revisit geocoding at all.

---

## 6. Downtime

Per-ride downtime breaks in several ways:
- chained and pooled rides make it negative
- the first ride of the day is measured against the previous night
- one missed capture poisons two values
- the engine has no cross-item window to compute it

Between shifts is off-duty time, and idle time within a shift isn't observable from two captures.

**Phase 1 reports hours online and earnings per week.** Their ratio (the real hourly rate) is
Phase 2. Until then, the driver divides the two cards.

---

## 7. Implementation steps

### Step 0. Preconditions (no repo or DB changes by the implementer)

**0.1. The closed_at migration.**
- `20261119000000_add_closed_at_field.sql` is applied to dev but untracked in git.
- **Ask the user to commit it as its own commit before this work starts.** That keeps this
  feature's commits clean. The plan doesn't otherwise depend on it.
- Step 4 re-runs `supabase migration list --linked` and stops if 20261119000000 isn't shown as
  applied remotely.
- Its effect on Step 6b: `closed_at` is optional, so `closed` keeps an empty required set and stays
  hidden.

**0.2. Address fields — no decision needed.** `start_address`/`end_address` are plain optional
text fields (Step 2), with no API key, no secret, and no branch to choose. See §5 and the
addendum for the full rationale.

**0.3. Test photos.** Ask for one or two real dashboard photos (one digital, ideally one analog)
for Step 5c. Keep them **untracked**, like `plans/diet-workflow/test-plate.jpg`.

### Step 1. Engine migration: `supabase/migrations/20261120000000_report_engine_signed_weights_timestamps_date_key.sql`

These are four generic extensions. The header comment explains each, cites this plan, and states:
- The derived-field "every component present" rule is unchanged.
- `item_date_key` reads live `item.data` only. That's safe for both configured keys:
  - Expenses' `date` is on its only stage.
  - `start_time` isn't shared between stages.
  - A future config pointing `item_date_key` at a key shared between stages would read only the
    current stage's value.
- Like 20261115010000, replacing `report_fields_valid` doesn't re-check existing rows. Re-adding the
  CHECK (1d) does.

No existing config changes behaviour. Nutrition output must be byte-identical (Step 4).

**On cutting `parse: "timestamp"`.** It exists only for the "Hours online" card. To cut it, delete:
- 1b
- the `parse` line in 1a
- the two `case` arms in 1e
- the `hours`, `start_time` and `end_time` entries in the Mileage config
- the hours assertions in Step 3 case 1

Nothing else depends on it. It's kept here: it's small and isolated, and hours is the denominator of
the driver's real productivity number.

**1a. Signed weights, plus `hidden`/`parse` validation.** This is `create or replace` with the same
signature, so the CHECK dependency is kept. The body is identical to 20261115010000 except the marked
lines.

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

**1b. `private.jsonb_epoch`:**

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

**1c. `private.item_local_date`:**

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

**1d. The CHECK gets `item_date_key`** (drop and re-add, with the existing clauses unchanged):

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

`note` is deliberately not validated, the same as `item_noun`. The client ignores a non-string
`note`.

**1e. `report_series`.** This is `create or replace` with the same signature and return type, still
`language sql stable security invoker`. Three CTEs change. **Every other CTE is copied verbatim from
20261115010000.**

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

Notes on 1e:
- `::timestamp` before `date_trunc` avoids the timestamptz overload's session-TimeZone dependency.
  For Nutrition it gives the same result as the old expression.
- With `item_date_key` absent, `i.data -> null` is null, `item_local_date` returns null, and the
  item falls back to `created_at`, which is the old behaviour.

**Rejected alternatives:**
- Storing `miles`/`hours` at capture. That breaks the never-stored precedent and goes stale on chat
  corrections.
- Storing epoch numbers alongside ISO strings. That gives two sources of truth.
- Dropping the expense `date`. A Dec 31 receipt logged Jan 2 would land in the wrong tax year.

### Step 2. Content migration: `supabase/migrations/20261120010000_add_rideshare_workflows.sql`

The header summarises:
- §2 (two workflows, shift unit)
- §3 (platform log as corroboration, `platform` required)
- key conventions (`{prefix}_odometer/_time/_address`, `*_usd`)
- the dependency on Step 1

Matching follows the Nutrition precedent: the account is matched via `'Joe''s Auto Repair'`,
workflows use `not exists`, and stages use `on conflict (workflow_id, title) do nothing`.

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
   '["start_odometer","start_time","platform","start_address"]'::jsonb,
   '["start_address"]'::jsonb),
  ('end',   2, false, true,
   '["end_odometer","end_time","end_address","tolls_usd","parking_usd","earnings_usd"]'::jsonb,
   '["end_address","tolls_usd","parking_usd","earnings_usd"]'::jsonb)
) as s(title, seq, is_initial, is_terminal, checklist, optional)
where w.name = 'Rideshare Mileage'
on conflict (workflow_id, title) do nothing;

-- Expense: one stage, both initial and terminal (a flat log). Every field optional: a missing
-- date falls back to created_at's local day; categories are mutually optional. The free-text
-- field is "description", not "note", so the agent doesn't confuse it with its add_note tool.
insert into public.stages (workflow_id, title, sequence_order, is_initial, is_terminal, checklist, optional_checklist)
select w.id, 'logged', 1, true, true,
  '["date","phone_usd","supplies_usd","other_usd","gas_usd","maintenance_usd","insurance_usd","description"]'::jsonb,
  '["date","phone_usd","supplies_usd","other_usd","gas_usd","maintenance_usd","insurance_usd","description"]'::jsonb
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

Config notes:
- **Miles and hours exist only for shifts with both captures.**
- **`item_requires` isn't used,** so tolls still count on a shift with a failed End capture.
- **Hidden base fields** exist only so derived-field validation passes.
- **The 1/3600 weight isn't exact.** An 8.5 h shift computes as 8.5000000000000068 h. That's
  invisible in the UI (`0.#` formatting), but tests must use a tolerance (Step 3).
- **No expense Total card.** A derived total is null whenever any category is missing. That needs a
  Phase 2 "missing = 0" option.

### Step 3. Dev check scripts

**`scripts/report_series_dev_check.sql`** (edit):
- **Delete** the `-- negative weight` entry (lines 96–97) from the reject array. **Keep**
  `-- zero weight`.
- **Append these five reject entries** to the array:
  ```sql
  -- hidden not a boolean
  '{"period": "week", "fields": [{"key": "x", "hidden": "yes", "item_agg": "sum", "period_agg": "avg"}]}',
  -- parse not "timestamp"
  '{"period": "week", "fields": [{"key": "x", "parse": "date", "item_agg": "sum", "period_agg": "avg"}]}',
  -- parse on a derived field
  '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "parse": "timestamp", "period_agg": "avg", "weights": {"x": 1}}]}',
  -- empty item_date_key
  '{"period": "week", "item_date_key": "", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}]}',
  -- non-string item_date_key
  '{"period": "week", "item_date_key": 5, "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}]}'
  ```
- **Update the count assertion** (line 118) from `33` to **`37`** (33 − 1 + 5), in both the
  condition and the message.
- **Add an accept block** right after the reject loop. Each `update` must succeed. Wrap each in
  `begin ... exception when check_violation then raise exception 'FAIL check: rejected %', ...; end;`.
  ```sql
  -- negative weight (now valid)
  '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "period_agg": "avg", "weights": {"x": -4}}]}'
  -- note + item_date_key + hidden + parse
  '{"period": "week", "note": "hi", "item_date_key": "d", "fields": [{"key": "t", "hidden": true, "parse": "timestamp", "item_agg": "last", "period_agg": "last"}]}'
  ```
  The script later restores `v_cfg` before the assertions that depend on it, so these temporary
  updates don't leak.

**New `scripts/rideshare_report_dev_check.sql`.** It runs after Step 4's push, because it needs the
real Rideshare workflows. It copies `report_series_dev_check.sql`'s structure:
- One `do $$` block that always ends by raising. Success is a message starting `PASS`, so every write
  rolls back.
- SETUP guards: both workflows and the owner were found, and there are no real items before
  2026-03-01 (so test weeks are isolated).
- **It switches to the real owner as `authenticated` before calling `report_series`**, exactly as
  the existing script does. This exercises the grants on `jsonb_epoch`/`item_local_date`.
- Test items are inserted with back-dated `created_at`, `America/Chicago`, in the week of
  2026-01-05.
- Numeric comparisons on `hours` use `abs(x - expected) < 1e-6`. Never use `=`.

Cases:

1. **Two shifts in the same week.**
   - Shift A: `start_odometer` 48000, `end_odometer` 48123, `start_time`
     `"2026-01-05T14:00:00Z"`, `end_time` `"2026-01-05T22:30:00Z"`.
   - Shift B: `start_odometer` 48200, `end_odometer` 48290, `start_time`
     `"2026-01-07T05:30:00Z"` (Jan 6, 23:30 local), `end_time` `"2026-01-07T09:30:00Z"`.
   - Expect one row with `period_start = '2026-01-05'`, `field_values->>'miles' = 213`, and
     `hours` ≈ 12.5 (8.5 + 4). Hidden keys are present in `field_values`, which is fine.
2. **An in-progress shift** (only `start_odometer`/`start_time`, in the same week) raises
   `item_count` by 1 and leaves `miles`/`hours` unchanged.
3. **Malformed end_time.**
   - `end_time = "yesterday"` on one shift, and `"2026-13-01T00:00:00Z"` on another.
   - Both contribute no hours and raise no error.
   - Also assert `private.jsonb_epoch('"2026-13-01T00:00:00Z"') is null` and
     `private.jsonb_epoch('"2026-01-05T14:00:00"') is null` (no offset).
4. **Expense date bucketing** (Rideshare Expenses, month period, query `2025-12-01..2026-01-31`).
   - Expense X: `created_at = '2026-01-02 15:00-06'`, `{"date": "2025-12-31", "gas_usd": 40}`.
     Expect it in period `2025-12-01`.
   - Expense Y: `created_at = '2026-01-02 15:00-06'`, `{"date": "Dec 31", "phone_usd": 10}`. It
     isn't parseable, so expect it in period `2026-01-01`.
   - Expense Z: no `date`, `created_at` in January. Expect January.
5. **Regression:** the edited `report_series_dev_check.sql` passes on its own.

**Before Step 4**, snapshot the real Nutrition output. The workflow name is verified in
`20261112000000`.

```bash
supabase db query --linked "select * from public.report_series((select id from public.workflows where name = 'Nutrition Tracker'), '2026-11-01', '2026-11-30', 'America/Chicago')" > /tmp/claude-1000/<session>/scratchpad/nutrition_before.txt
```

Use the implementing session's scratchpad path.

### Step 4. Push migrations to dev and verify

```bash
cd /home/mmcbride/micah/claude/workflow-app
supabase migration list --linked      # every local migration through 20261119000000 has a remote; stop if not
supabase db push --linked --dry-run
```

The dry run must list **exactly** these files:
- `20261120000000_report_engine_signed_weights_timestamps_date_key.sql`
- `20261120010000_add_rideshare_workflows.sql`

If it lists anything else, including `20261119000000`, stop and ask the user.

```bash
supabase db push --linked
supabase db query --linked -f scripts/report_series_dev_check.sql      # expect PASS
supabase db query --linked -f scripts/rideshare_report_dev_check.sql   # expect PASS
# re-run the Nutrition snapshot query to nutrition_after.txt; diff the two -- must be identical
```

### Step 5. Edge functions

**5a. `supabase/functions/scan-odometer/index.ts`.** Copy `supabase/functions/scan-plate/index.ts`
and keep its `RequestBody`, `corsHeaders`, OPTIONS/405/401/400 handling, Anthropic call shape, and
200/422/502 status semantics. Replace the header comment, the result type, the validator and the
prompt:

```ts
// Single-purpose odometer reading from a dashboard photo (2026-11-20). Same shape and reasoning
// as scan-vin/scan-plate: one-shot, no chat history, photo never stored. Exact-digit OCR like
// scan-vin, but a cluster shows several numbers (trip A/B, range, speed) and analog odometers
// have a tenths drum, so the model must say which number it read and the caller validates.
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

// null from parseReading -> 422; success -> 200 {reading, unit, note}; upstream failure -> 502.
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

**5b. `supabase/config.toml`.** Add this after `[functions.scan-plate]`, with a one-line comment
pointing at scan-plate's reasoning.

```toml
[functions.scan-odometer]
verify_jwt = true
```

**5c. Check, deploy and smoke-test:**

```bash
deno check supabase/functions/scan-odometer/index.ts
supabase functions deploy scan-odometer --project-ref utwyvtbzesswpoihmlic --use-api
supabase functions list --project-ref utwyvtbzesswpoihmlic        # ACTIVE, verify_jwt true
```

Smoke test:
- **`scan-odometer`:** curl it with the user's photos and a user JWT, as in the scan-plate plan.
  Expect the ODO reading, not a trip meter. A blurred or dark photo should give 422.

**5d. `agent-loop`: today's date in the system prompt** (generic, and it benefits every workflow).
- **Client:** `SendAgentMessageAsync` gets one more optional parameter, `string? clientLocalDate =
  null`. It's sent as `["client_local_date"]`. The caller in `WorkflowDetail.razor` (~line 1053)
  passes `DateTime.Now.ToString("yyyy-MM-dd (dddd)", CultureInfo.InvariantCulture)`. That's the
  browser's local date, the same notion of "today" the report uses.
- **Function:**
  - `systemPrompt(...)` gets a `clientLocalDate?: string` argument, passed from
    `body.client_local_date`.
  - When it's a string matching `^\d{4}-\d{2}-\d{2} \(\w+\)$`, append one line after the stages
    block: `Today's date in the user's local time zone is ${clientLocalDate}. Resolve relative dates
    ("yesterday", "last Friday") against it. Write a date-only field (a key named "date") as
    YYYY-MM-DD; write a date-time field as ISO 8601 with an offset.`
  - Otherwise, omit the line. Older clients behave as today.
- **Deploy:**
  ```bash
  supabase functions deploy agent-loop --project-ref utwyvtbzesswpoihmlic --use-api
  ```
  Then confirm a mechanic chat still works (send a message on an existing job).
- The prompt is already rebuilt per request, and the comment at ~line 370 accepts that. A date line
  that changes once a day adds no new cache concern.

### Step 6. Web changes

`start_address`/`end_address` need no new file and no new step here: they're plain optional text
checklist fields, rendered and saved by the app's existing generic checklist editor exactly like
`platform`. No JS, no new C# method, no new UI block.

**6a. `web/Services/WorkflowApiClient.cs`:**
- **`ReportField`** (line 9): append `bool Hidden = false` as the **last** positional parameter,
  after `Weights`. At line 139, pass
  `f["hidden"] is JsonValue hv && hv.TryGetValue<bool>(out var h) && h`.
- **`ReportConfig`** (line 11): append `string? Note = null` as the last parameter. Next to the
  `itemNoun` parse (~line 102), add
  `var note = obj["note"] is JsonValue nv && nv.TryGetValue<string>(out var n) ? n : null;`. At
  line 144, construct `new ReportConfig(period, itemNoun, fields, note)`.
- **Add** `public record OdometerScanResult(double Reading, string Unit, string Note);` next to
  `FoodScanResult`.
- **Add `ScanOdometerAsync(string imageBase64, string mediaType)`**, returning
  `OdometerScanResult?`. Model it on `ScanFoodPhotoAsync`: null on 422, throws on other non-2xx.
- **`SendAgentMessageAsync`:** add the `clientLocalDate` parameter (Step 5d).
- `parse` and `item_date_key` stay server-only.

**6b. `WorkflowDetail.razor`, list visibility.** Replace `VisibleItems()` (lines 596–599). Update
its comment to state the new rule: an item is "closed" when it's **in a terminal stage that isn't
also initial, with that stage's required fields filled.**

```csharp
private bool IsClosed(ItemSummary i) =>
    _stages!.FirstOrDefault(s => s.Id == i.StageId) is { IsTerminal: true, IsInitial: false } st
    && st.Checklist.Except(st.OptionalChecklist)
         .All(f => i.Data.TryGetPropertyValue(f, out var v) && v is not null);

private IEnumerable<ItemSummary> VisibleItems() =>
    _showClosed ? _items! : _items!.Where(i => !IsClosed(i));
```

| Stage | Required set | Result |
|---|---|---|
| Joe's `closed` | empty (`closed_at` optional) | Hidden, as today |
| Joe's `payment_receipt_submitted` | `payment_method` | **Changed:** visible until `payment_method` is set (0 items on dev today) |
| Nutrition `dinner` | empty | Hidden, as today |
| Feature Pipeline `deploy` | empty (null checklist) | Hidden, as today |
| Expenses `logged` | initial stage | Never hidden. Fixes the empty list. |
| Shift `end` | `end_odometer`, `end_time` | Visible until both are captured. Fixes the vanishing shift. |

Rejected alternatives:
- Special-casing by `item_label`. That cuts against the generic engine.
- "Terminal and not initial" alone. It fixes Expenses but not the shift that vanishes before its End
  capture.

**6c. `WorkflowDetail.razor`, display-name disambiguation.** In `ItemDisplayName` (lines 629–633),
non-job branch only:

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

- Grouping is by the item's **own** current stage, so a name is stable across the list, the
  overview and the stage headers.
- The check is computed per call. It's O(n²) per render at hundreds of items, which is negligible,
  and it avoids keeping a cache in sync across the six `_items` reassignments.
- Two same-day expenses read "Logged 2026-11-19 09:12" and "Logged 2026-11-19 14:05". Nutrition is
  unchanged.
- Known limitations, accepted:
  - It covers only loaded items (up to the 1000-row cap).
  - The name uses `created_at`, not the expense's `date`. A back-dated expense is named by the day it
    was logged, and its report bucket uses `date`.

**6d. `WorkflowDetail.razor`, `_usd` prefix rendering and date-only display.** Five edits.

1. **Table** (line 697):
   ```csharp
   private static readonly (string Suffix, string Unit, bool Prefix)[] FieldUnitSuffixes =
       [("_g", "g", false), ("_lbs", "lbs", false), ("_usd", "$", true)];
   ```
   Update the comment above it (it says "just _g and _lbs today").
2. **`FieldLabelAndUnit`** (lines 699–707): returns `(string Label, string Unit, bool Prefix)`. The
   fallback is `(ChecklistLabel(field), "", false)`. Line 81 is its only caller.
3. **New helper:**
   ```csharp
   private static string UnitValueText(string field, JsonNode? v, string unit) =>
       unit == "$" && v is JsonValue jv && jv.TryGetValue<double>(out var d)
           ? d.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture)
           : FieldText(field, v);
   ```
   Agent-written numeric strings (`"12.5"`) fall through and show as `$12.5`, consistent with
   `_g` today.
4. **Call site** (line 81 and lines 89–92):
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
5. **`FieldText` date-only branch.** Before the existing date-ish arm, add an arm that matches a
   string value of exactly `yyyy-MM-dd` (use
   `DateOnly.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)`)
   on a date-ish key, and formats it `"MMMM d, yyyy"`. Without it, an expense date shows as
   "December 31, 2025, 12:00 AM". No existing field stores a bare date, so nothing else changes.

Results:
- `tolls_usd = 12.5` shows as `☑ $12.50 Tolls`.
- `protein_g = 43` shows as `☑ 43g Protein`, byte-identical to today.
- The overview "Details" list (line 328) keeps `Tolls usd: 12.5`, consistent with `Protein g: 43`
  today.

**6e. `WorkflowDetail.razor`, odometer capture block.** Place it after the Scan Plate block, using
the same current-stage-only gating and the same hidden-`InputFile`-behind-a-label pattern as Scan
VIN (lines 101–124).

**Gating.** The block renders when all of these hold:
- `_selectedStageId == _selectedItem.StageId`
- the current stage's checklist has a key ending `_odometer`
- `prefix` = that key minus `_odometer`

`{prefix}_time` and `platform` are written only when they're on that stage's checklist. That makes
this a checklist convention, the same kind as `vin` and `protein_g`, not a Shift-specific hardcode.
`{prefix}_address` is a separate, ordinary optional text field on the same stage -- the generic
checklist editor already renders and saves it, with no special gating or code in this block at all.

**UI:**
```
[ Scan odometer ]   or type reading: [______] [Save]
Platform: [Uber______] [Save]                      <- only if the stage checklist has "platform"
Address: [______________________] [Save]           <- plain checklist field, generic editor
hint: "Ignition on so the odometer is lit; photograph the ODO number, not a trip meter. For
       address, paste it from the Uber/Lyft driver app if handy."
tip:  "For taxes, also download your Uber/Lyft trip history and annual tax summary and keep
       them with this log -- two consistent records are stronger evidence than one. If you
       start this shift before going online, this log also covers miles the platform summary
       doesn't count at all."
(after a capture)  Odometer 48,213.0 -- Correct reading: [______] [Fix]
(warnings/errors line, same styling as _vinScanError)
```

**Reading numbers from `item.Data`.** The agent may write odometers as strings. Read them with a
small helper:
- If the value is a JSON number, use it.
- Else, if it's a string, strip whitespace, `$` and `,`, then `double.TryParse` with
  `InvariantCulture`.
- Else, null.

This mirrors `private.jsonb_numeric`.

**Platform pre-fill:**
- When the block first renders for an item without `platform`, set `_platformInput` to the
  `platform` of the most recent *other* item in `_items` that has one (by `CreatedAt` desc).
  Otherwise leave it empty.
- The Platform [Save] writes only `platform`.
- If the box is empty at capture time, the patch omits `platform`. The checklist then shows
  `☐ Platform *`, and Complete Stage stays hidden.

**`CaptureAsync(prefix, double reading, string source, string? modelNote)` flow:**

1. **Capture time.** Take `captureStartedAt = DateTimeOffset.UtcNow` when the photo is selected or
   typed Save is tapped. Format `{prefix}_time` as
   `captureStartedAt.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)`.
2. **Scan** (photo path). Resize with `RequestImageFileAsync("image/jpeg", 1600, 1600)` and call
   `ScanOdometerAsync`.
   - null → "Couldn't read the odometer -- try again, or type the reading."
   - `Unit == "km"` → "Odometer appears to be in km -- switch the display to miles or type the
     reading in miles."
   - Either ends the flow. Nothing is written.
3. **Plausibility.** Client-side only, with no new RPC.
   - **(i) End vs. Start.** For `prefix == "end"`, compare with this item's `start_odometer`:
     - lower → block
     - more than 1,000 above → block unless typed
   - **(ii) Start vs. the previous shift.** For `prefix == "start"`:
     - Look at other items in `_items` with a numeric `end_odometer`. `GetItemsAsync` loads all
       stages, so closed shifts are present.
     - Pick the one with the greatest parsed `end_time`, falling back to `CreatedAt`.
     - If the new reading is below its `end_odometer`, warn and save, naming both numbers.
   - **Block** shows the message and puts the value in the typed box for one-tap override. **Warn**
     saves and shows the message.
4. **Patch:**
   - `{prefix}_odometer` always.
   - `{prefix}_time` only if unset, so a re-scan doesn't move the shift start.
   - `platform` only if it's on the checklist, unset, and `_platformInput` isn't empty.
5. **Write.** Call `UpdateDataAsync`, then
   `AddNoteAsync(item, $"{Prefix} odometer {reading:N1} mi ({source}){modelNote}", _selectedStageId)`.
6. **Reload** items and notes, with the same tail as `OnVinPhotoSelected`.

`{prefix}_address` isn't part of this flow at all -- it's a plain checklist field saved through the
existing generic editor whenever the driver types or pastes into it, independent of the odometer
capture.

**Fix** writes only `{prefix}_odometer`, plus the note
`"Corrected {prefix} odometer {old} -> {new}"`.

**Stage advance stays manual** (Complete Stage). On Start, it appears once `start_odometer`,
`start_time` and `platform` are set. Auto-advance was rejected: a stray tap on the then-visible End
scan would end the shift seconds after it started.

**6f. `web/Pages/WorkflowReport.razor`:**
- Change the card loop to `@foreach (var field in report.Fields.Where(f => !f.Hidden))`.
- If `report.Note` is non-null, render it as `<p style="opacity:0.75;">@report.Note</p>`
  **directly after the `<h1>`, before the period-stepper `div`**. The note is about the workflow,
  not the selected period, so it sits above the stepper and doesn't move as periods change.
- `mi` and `h` format via the existing default branch (`0.#`).

**6g. Build:** run `dotnet build web/`, then a local run for a UI pass. Deploy (push to `main`) only
when the user asks to commit and push.

### Step 7. Live checks on a phone (dev site)

1. **Expenses:**
   - "+ New Expense", then chat "$42.10 gas yesterday". The item stays in the list. The checklist
     shows `$42.10 Gas` and `Date: <yesterday as "Month d, yyyy">`.
   - Add a second expense the same day. Both list names gain `HH:mm`.
   - Report: the month card shows $42.10, the note is above the stepper, and there's no Total card.
   - An expense dated last month (by chat) lands in last month.
2. **Shift:**
   - "+ New Shift". Platform is empty on the very first shift, and pre-filled after that.
   - Scan at the car. The reading and time are captured; the tax tip is visible.
   - Type or paste a start address into the plain Address field and Save it.
   - With platform empty, Complete Stage is hidden. Fill it, and Complete Stage appears.
   - On End, scan. A deliberately lower typed reading is blocked.
   - Add tolls via chat. They show as `$x.xx Tolls`.
   - The Report week shows miles, hours and tolls matching hand arithmetic, plus the note.
   - The shift leaves the list only after End's capture.
3. Leave the address field blank on one shift. The capture still saves normally.
4. **Regressions:**
   - The Nutrition report is unchanged.
   - The Nutrition checklist still shows `43g Protein`.
   - The mechanic Jobs list is unchanged.
   - A mechanic chat message still works (Step 5d).

---

## 8. Risks, edge cases, rollback

- **Engine regression on Nutrition.** Mitigations: verbatim CTE copies, the updated dev check, and
  the before/after diff.
- **CHECK re-add failing.** It can only fail on clauses already enforced today, and the migration
  transaction rolls back.
- **Clock skew.** `{prefix}_time` is the phone clock. `item_events.created_at` is the server
  corroboration.
- **Shifts crossing midnight or a week boundary** belong to their start date and week. That's
  intended.
- **Negative miles from a bad chat correction.** The client checks cover only the capture path.
  Accepted.
- **Plausible single-digit misreads.** Accepted (§4).
- **The agent picks the wrong `*_usd` key.** It sees stage checklists in its prompt. A prompt hint
  is a later tweak if needed.
- **The agent writes `date` in another format.** It falls back to `created_at`. Step 5d's
  instruction makes `YYYY-MM-DD` the norm.
- **Stale platform pre-fill.** It's visible and editable. Accepted.
- **`payment_receipt_submitted` visibility change** (6b). It's intended, and the user was told up
  front.

**Rollback, in this order:**

1. **Web:** revert the commit(s) and push to `main`.
2. **Functions:**
   ```bash
   supabase functions delete scan-odometer --project-ref utwyvtbzesswpoihmlic
   ```
   - Remove the `config.toml` block.
   - For `agent-loop`, revert the 5d edit and redeploy. It's harmless to leave, since old clients
     omit the date.
3. **Content.**
   - **Ask the user first.** Once real driver data exists, this deletes tax records. Offer a CSV
     export of `items.data` for both workflows beforehand.
   - Save the SQL below as `scripts/rideshare_content_rollback.sql` and run
     `supabase db query --linked -f scripts/rideshare_content_rollback.sql`.
   - The CLI role bypasses RLS, and there are no append-only triggers.
   ```sql
   begin;
   create temp table rb_wf on commit drop as
     select id from public.workflows where name in ('Rideshare Mileage', 'Rideshare Expenses');
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
   Then delete `20261120010000_add_rideshare_workflows.sql` from the repo and run:
   ```bash
   supabase migration repair --status reverted 20261120010000 --linked
   ```
4. **Engine.** Write a new forward migration, `2026112X..._revert_report_engine_extensions.sql`,
   that:
   - re-issues the 20261115010000 `report_fields_valid` and `report_series` verbatim
   - drops and re-adds the original CHECK. This fails loudly if any config still uses
     `item_date_key`, which is the intended guard.
   - drops `private.jsonb_epoch(jsonb)` and `private.item_local_date(jsonb, text)`

   Also revert the `report_series_dev_check.sql` edits, including the count back to 33.

---

## 9. Assumptions

1. **The aggregation citation is confirmed.** 26 CFR 1.274-5T(c)(6)(i)(C), "Aggregation of business
   use", reads: "Uses which may be considered part of a single use, for example, a round trip or
   uninterrupted business use, may be accounted for by a single record." (Cornell LII text, checked
   by the round-2 sanity check.) It can be stated as settled in the migration header. Whether a
   shift log plus platform trip history meets §274(d) is still a tax professional's judgment.
2. **The *Brown*/*Ressen* characterisation** comes from the round-1 sanity check. The opinions
   weren't read.
3. **Home-to-first-pickup miles** with the app on are contested as business vs. commuting. The shift
   starts wherever the driver taps Start.
4. **`claude-sonnet-5-5` tells ODO from trip meters** on the user's cluster. Checked in Step 5c.
5. **The standard mileage rate isn't used anywhere.**

---

## 10. Out of scope

- **Phase 2 engine features:** group-by (per-area, per-category), ratio-of-sums (earnings per hour),
  a cross-item window (personal miles, downtime, history-based plausibility), a derived
  "missing = 0" (an expense Total), and a per-workflow period switcher.
- **Annual business-use % and the Schedule C line 44 split.** These need Jan 1 / Dec 31 readings and
  the cross-item gap.
- **Multi-vehicle support.**
- **Storing odometer photos as evidence.** Deferred to a possible Phase 1.5 opt-in private bucket,
  which needs its own retention and privacy decision.
- **Importing platform trip history or tax exports.**
- **Item deletion and retention controls.**
- **Any mileage-rate deduction estimate.**
- **Extracting the odometer block into its own component.** WorkflowDetail.razor is large, but VIN
  and Plate scans are inline. Follow the convention now and consider a refactor of all three later.
- **Prod.** Nothing is ported. Add this to the dev-only list in `PROGRESS.md` at the next milestone.

---

## Architect adjudication

Inputs: `round-2-draft.md` and `round-2-sanity-check.md`. **`round-2-review-notes.md` doesn't exist
on disk.** The plan-reviewer's five notes were adjudicated from the orchestrator's summary of them.

### Plan-reviewer notes (all minor)

| # | Finding | Decision |
|---|---|---|
| R1 | 6b: record-field insertion point and call sites not spelled out | **Valid, fixed.** `Hidden`/`Note` are appended as last positional params with defaults. The only two constructor calls (lines 139, 144) are named, verified by grep. |
| R2 | 6b: "above the cards" ambiguous relative to the period stepper | **Valid, fixed.** The note goes directly after `<h1>`, before the stepper, because it describes the workflow, not the period. |
| R3 | Step 3 test cases in prose, not SQL | **Partly valid, fixed where it matters.** The `report_series_dev_check.sql` edits are now literal, including the reject-count change from 33 to 37 that the draft missed (the existing assertion would have failed). The rideshare script's cases now give exact inputs and expected outputs, plus the hours tolerance. The full `do $$` body is left to the implementer, who copies the existing script's structure. |
| R4 | Step 0.1/Step 4 tie-together for the untracked closed_at migration | **Valid, fixed.** Re-verified as applied on dev today. Step 0.1 asks the user to commit it first. Step 4's dry-run stop condition is now "anything other than the two files". |
| R5 | 5a/5b "identical to scan-plate" without naming the file | **Valid, fixed.** Both name `supabase/functions/scan-plate/index.ts` as the copy source and say what's kept and what's replaced. |

### Sanity-check notes (all non-blocking)

| # | Finding | Decision |
|---|---|---|
| S1 | The "decline LocationIQ" path isn't wired to steps | **Valid, fixed.** Step 0.2 Branch B lists every affected step. The rounded-coordinate fallback is dropped rather than wired, because it discloses the same as a label and serves no report. "No area" is the cleaner decline path. |
| S2 | Name an offline reverse-geocode alternative | **Adopted as a named, rejected-for-Phase-1 alternative** (§5). It's strictly better on privacy, but it means sourcing and maintaining boundary data for a label no Phase 1 report reads. It's the right thing to revisit with Phase 2's per-area breakdown. |
| S3 | 5d's logging check covers inbound logs only | **Valid, one-line fix** in §5, 5d and §9.5. |
| S4 | §9.1 citation hedge is stale | **Valid, fixed.** §9.1 now states it as confirmed, with the quoted text. |

### Issues neither earlier stage caught (found by checking the plan against the code)

1. **The agent has no notion of today's date** (`agent-loop/index.ts`: the system prompt has no
   date, and the client sends none). Expenses are entered almost entirely by chat, and the
   `item_date_key: "date"` design exists so "a Dec 31 receipt logged Jan 2" lands in the right year.
   That only works if the agent can resolve "yesterday" or "Dec 31" to a concrete date. Draft live
   check 7.1 ("$42.10 gas yesterday") would have been unreliable. **Added Step 5e**, a small,
   generic, backward-compatible prompt line.
2. **6b's stage table missed `payment_receipt_submitted`**, a mechanic terminal stage with a
   required field. The new rule changes its visibility. It's the correct semantics and has no effect
   on current dev data, but it's an unannounced mechanic behaviour change. **Added to the table and
   flagged to the user.**
3. **The reject-count assertion** (`v_rej <> 33`) would have failed after the draft's script edits.
   **Fixed: 37.**
4. **The 1/3600 weight isn't exact in numeric arithmetic** (8.5 h → 8.5000000000000068). It's
   invisible in the UI, but an `=` assertion in the check script would fail. **Tolerance specified.**
5. **The Expenses `note` data key collided conceptually with the agent's `add_note` tool** (and with
   the new top-level `report_config.note`). **Renamed to `description`.**
6. **Bare `YYYY-MM-DD` dates would render as "…, 12:00 AM"** via `FieldText`. **Added 6b edit 5.**
7. **Odometer values may be agent-written strings.** The plausibility checks now read them with a
   `jsonb_numeric`-equivalent helper instead of assuming JSON numbers.

### Architectural fit

The plan fits the system:
- New workflows are pure content (checklists plus `report_config`), with no per-workflow code paths.
- Engine changes extend the existing jsonb-config-plus-one-RPC model the same way `item_requires`
  did. They're validated in the CHECK, invisible to existing configs, and verified by a byte-diff.
- New edge functions follow the scan-vin/scan-plate one-shot shape.
- The capture block is gated by a checklist-key convention (`*_odometer`), exactly like `vin` and
  `protein_g`.

Two places lean on the architecture and are accepted with eyes open:
- **6b redefines "closed"** generically using `optional_checklist`. That's the right generalisation,
  but it couples list visibility to checklist completeness. Any future terminal stage with required
  fields will show until they're filled.
- **WorkflowDetail.razor keeps growing.** It already has two inline scan blocks, and this adds a
  third, larger one. It follows convention now. Extraction is noted in §10.

One judgment call kept as designed: **the area label is collected in Phase 1 but read by nothing in
Phase 1.** It costs a third-party account, a secret, a JS file, an edge function, and residual
privacy exposure. It's kept because history can't be backfilled and location was in the user's
original ask, but Step 0.2 makes it a clean, explicit user choice.

## Verdict: approved-with-changes

What changed from round 2:
- Agent-date Step 5e added.
- 6b table corrected, with the mechanic visibility change flagged.
- Dev-check count, the hours tolerance and literal SQL cases.
- Expense `note` → `description`.
- Date-only display fix.
- Numeric-tolerant odometer reads.
- Step 0.2 Branch B fully wired.
- All five reviewer and four sanity-check notes folded in.

None of these changes the design. The plan is ready to execute once the user acknowledges the
`payment_receipt_submitted` visibility change and the `agent-loop` edit, and commits the closed_at
migration. (Step 0.2's LocationIQ decision was later removed by a post-approval change — see the
addendum below.)

---

## Addendum (2026-11-19): GPS/reverse-geocoding replaced with manual address entry

After the architect review above approved this plan, the user asked to drop GPS-based location
tracking in favor of plain address fields the driver fills in by hand (e.g. copied from the
Uber/Lyft driver app's own trip screen). This was a direct request, not a re-run of the review
pipeline, so it's recorded here rather than folded silently into the sections above.

**What changed:**
- `start_area`/`end_area` (GPS → rounded coordinates → LocationIQ reverse-geocode → label) are
  replaced by `start_address`/`end_address`: plain, optional, free-text checklist fields with no
  special capture code — they're rendered and saved by the engine's existing generic checklist
  editor, the same as `platform`.
- Removed entirely: the `reverse-geocode` edge function, `LOCATIONIQ_API_KEY` secret,
  `geolocation.js`, `ReverseGeocodeAsync`, the Step 0.2 LocationIQ/"no area" branch decision, and
  every piece of the capture flow that waited on or patched an area value.
- Step numbering in §7 (web changes) shifted down by one across the board (old 6b–6h → 6a–6g) now
  that the old 6a (`geolocation.js`) is gone.
- The capture-tip wording now suggests pasting the address from the Uber/Lyft driver app, which
  doubles as a (free) tie-in to the §3 trip-history-corroboration story.

**Why:** nothing in the Phase 1 report reads the area label — it existed only to seed a possible
Phase 2 per-area breakdown. Given that, keeping a third-party geocoding vendor, an API key, and a
privacy disclosure alive for a field nothing uses yet wasn't worth it. Manual address entry gets
the same future option (grouping/reporting by address text later) with zero coordinates collected,
zero third-party exposure, and no vendor dependency — at the cost of a few seconds of typing at a
parked, unhurried moment (shift start/end), which isn't a real burden the way mid-drive photo
capture would be.

**What this does *not* change:** the shift-vs-ride decision, the tax-substantiation design (§3),
the odometer-scan risk/fallback design (§4), the report-engine extensions (§1/Step 1), the
Expenses workflow, and the `agent-loop` date fix (Step 5d) are all unaffected.

If a future Phase 2 wants a true per-area productivity breakdown, revisit geocoding then — the
offline point-in-polygon alternative noted in the original §5 (now superseded) is still the
better starting point than reintroducing a third-party API.
