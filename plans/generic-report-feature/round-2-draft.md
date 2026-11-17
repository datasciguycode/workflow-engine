# Generic per-workflow Report: round-2 draft

Dev only: repo `/home/mmcbride/micah/claude/workflow-app`, Supabase project `workflow-engine-test`
(ref `utwyvtbzesswpoihmlic`, linked). Nothing here touches `workflow-app-prod`.

This revision fixes round 1's two blocking defects: `sum` fields double-counted on re-crossed stage
boundaries, and a CHECK constraint that let NULLs through. It also folds in the reviewer's polish
items. Everything the review rounds confirmed is unchanged: the security-invoker RLS reasoning,
capturing `v_cleared` from the pre-update row, `jsonb_object_agg`'s empty-aggregate behaviour,
`WorkflowSummary` constructor compatibility, and the overall architecture (jsonb config on
`workflows`, dated append-only goals, a server-side RPC, no chart dependency). The round-by-round
reasoning is at the end.

## 0. Ground truth (checked read-only against dev, 2026-11-15)

Read: CLAUDE.md, PROGRESS.md, every migration, `WorkflowDetail.razor`, `WorkflowApiClient.cs`,
`web/wwwroot/css/app.css`, `agent-loop/index.ts`, `scripts/*.py`,
`plans/diet-workflow/final-plan.md`. Plus read-only `supabase db query --linked` selects against
dev.

### 0.1 The task brief describes the Nutrition Tracker data model wrongly, and it matters

The brief says each meal is a separate item, with macros as flat totals in `item.data`. That design
was superseded and never built. What actually exists (`20261112000000_add_nutrition_tracker_workflow.sql`,
`20261113000000_move_stage_clears_shared_fields.sql`):

- **One item per day** (`item_label = 'meal date'`). It moves forward through
  breakfast → brunch → lunch → linner → dinner (`sequence_order` 1–5). All five stages use the same
  checklist keys (`protein_g, carbs_g, fat_g, fiber_g, sugar_g, weight_lbs`).
- **`move_stage` clears the shared keys from `item.data` on every forward move**, including forward
  skips. Backward moves clear nothing. So right after a forward move, `item.data` holds only the
  current stage's values. Breakfast's numbers leave `item.data` when the item reaches Brunch. After
  that they exist only as the last `item.data_changed` patch logged before the move.
- **Values are running totals per stage, not deltas.** Scan Plate writes `existing + scanned`
  (`ExistingPlus` in `OnFoodPhotoSelected`). Chat corrections write absolute values.
- **Nutrition Tracker has `enforce_stage_order = false`** (the column default; its migration never
  sets it). So forward skips such as breakfast → lunch are allowed. D1 depends on this.
- Nutrition Tracker was created in the **same account** as `Joe's Auto Repair` (its migration copies
  that workflow's `account_id`). One owner user can therefore reach both workflows, which Step 4's
  checks rely on.

Consequence: you can't get a daily total by summing `item.data` across a day's items. For any day
that got past Breakfast, that drops every earlier meal. D1 handles this.

Live dev data (4 Nutrition items, one per day):

| item | created_at (UTC) | stage now | moves |
|---|---|---|---|
| `a831e45f` | 2026-11-13 03:53 | dinner | 4 forward moves (seq 41, 42, 44, 54) |
| `b173bc11` | 2026-11-13 12:45 | breakfast | none |
| `fdd1665e` | 2026-11-14 13:20 | breakfast | none |
| `8c4775d6` | 2026-11-15 14:30 | breakfast | none |

- Every macro value is a JSON **number**. Some items also have non-numeric keys (`description`,
  `eaten`).
- Item `a831e45f` was created at 03:53 UTC, which is **21:53 on 11-12 in America/Chicago**. Bucketed
  by UTC date it would share a day with `b173bc11`. This is concrete proof that day bucketing needs
  a timezone (D5).
- Mechanic: the one job that has `estimate_amount` and `invoice_amount` stores both as JSON numbers
  (300, 500).
- Mechanic checklists (dev DB only, not in migrations): estimated = `estimate_amount`,
  `estimated_completion`; invoicing includes `invoice_amount`. No two mechanic stages share a key,
  so `move_stage` never clears anything there and `item.data` is the item's full record.
- **Job numbers are `row_number() over (order by created_at)`** (`20261108030000`), not a sequence.
  Creating items inside a transaction that is later rolled back leaves no gap in job numbers. The
  only side effect is skipped `item_events.seq` values, which are used only for ordering.

### 0.2 How this repo runs SQL against dev

- **No `psql` is installed.** SQL against dev goes through `supabase db query --linked` (CLI
  v2.120.0), either inline or with `-f <file>`. It runs through the Management API, not a psql
  session, so there are no `\set`/`\gset` variables. `plans/prod-instance-setup/round-3-draft.md`
  rejected `psql -v` for the same reason.
- `scripts/phase*_test.py` hard-code `http://127.0.0.1:54321` and the local JWT secret. They target
  the **local** stack only and can't be pointed at dev.
- So every write-path check in this plan is **one self-contained `do $$ … $$` block** in a `.sql`
  file:
  - It captures ids in plpgsql variables.
  - It asserts with `raise exception 'FAIL …'`.
  - It **always ends with `raise exception 'PASS …'`.**
- A `DO` block is a single statement, and an uncaught exception aborts all of it. So every write is
  rolled back whether it passes or fails, and whether or not the Management API wraps the call in a
  transaction. The "result" is the error message the CLI prints. A message starting with `PASS` is
  success, even though the CLI exits non-zero.

### 0.3 Special-casing precedent in `WorkflowDetail.razor`

The page is generic, but it has special cases of two kinds.

- **`item_label == "job"` branches:**
  - the stage-detail header suffix (line 58);
  - list and search cards `#N title` (lines 283, 304);
  - `ItemDisplayName` (line 629);
  - `StartNewJob`'s chat-first creation (line 734).
- **Field-name capability gates:**
  - `Checklist.Contains("vin")` turns on Scan VIN;
  - `Checklist.Contains("protein_g")` turns on Scan Plate, and `OnFoodPhotoSelected` hard-codes the
    five macro keys;
  - `Checklist.Contains("scheduled_at")` turns on Other Appointments;
  - `FieldUnitSuffixes` hard-codes `_g` and `_lbs`.

So the accepted level is "branch on a generic property or a well-known field name, never on a
workflow's name or id". **This plan adds no new branch of either kind.** The Report is gated only on
the new `workflows.report_config` being set.

### 0.4 Styling tokens actually in use

- `--app-accent` (`#2b88d8`, defined in `app.css`) is the app's accent colour. It's used for
  card titles, the current-stage border and `.current-badge`.
- Status colours use Fluent tokens with a hex fallback, for example
  `color:var(--colorPaletteRedForeground1, #c00)` on the scan error lines (`WorkflowDetail.razor`
  lines 122 and 152). There's no green anywhere yet.
- Buttons use `Appearance="ButtonAppearance.Primary"` (lines 44, 115, 141, 265, 361).

### 0.5 Why the old "Nutrition Goal" stage was dropped, and why it doesn't apply here

The superseded design had a `nutrition_goal` stage. The design that got built has exactly one
`is_initial` stage, so goals can't be items in that workflow. Its migration also notes "goals aren't
a daily-recurring thing anyway". Both objections are about modelling goals as items or stages.
Here, goals (D4) are rows in a side table, so neither objection applies.

## 1. What gets built (shape)

1. **Snapshot on clear.** `move_stage` records the values it clears inside its own
   `item.stage_changed` event (`data = {"cleared": {...}}`).
2. **Config.** A new nullable `workflows.report_config jsonb` says:
   - which `data.*` keys to report;
   - how each one aggregates;
   - its unit, label and goal direction;
   - the period (day, week or month).

   `null` means no report.
3. **Read path.** One `report_series` RPC (security invoker) returns per-period aggregated values for
   a date range in a caller-supplied timezone. Cleared snapshots are deduped per (item, departing
   stage, field) before aggregating (D1).
4. **Goals.** A new append-only `report_goals` table holds dated targets per (workflow, field).
5. **UI.** A new generic page `/workflow/{WorkflowId}/report` (`WorkflowReport.razor`), linked from
   `WorkflowDetail`'s list view only when `report_config` is set.
6. **Content.** Nutrition Tracker gets a `report_config`. The mechanic does not. Step 7 dry-runs a
   mechanic config in a rolled-back block, which also exercises the `week` path.

## 2. Decisions

### D1. Per-stage values are captured at write time, deduped per stage at read time

**Write side (unchanged from round 1).** In `move_stage`, before `data - v_shared_keys` runs, build
`jsonb_object_agg(k, data->k)` over the shared keys that are present. Store it as
`{"cleared": <obj>}` in the `item.stage_changed` event's `data`, which is always null today. It
stays null when nothing is cleared, so the mechanic and Feature Pipeline log exactly what they do
today.

**Read side (fixed in round 2).** An item's value for field `k` is computed in three steps:

1. **Segments.** Each segment is a `(stage, seq, value)` triple from one of two sources:
   - a **cleared snapshot**: `stage = from_stage_id`, the stage the item was leaving when the value
     was cleared, plus that event's `seq` and `cleared->k`;
   - the **live value**: `stage = items.stage_id`, `seq = +∞`, value `data->k`.
2. **Dedupe.** For each `(item, stage, k)`, keep only the segment with the highest `seq`.
3. **Combine.** Combine the surviving per-stage values with the field's `agg`: `sum`, `avg`, or
   `last` (= highest `seq`).

**What this means.** For each stage the item has been at, the report uses the value that field had
the last time the item was there. That's the live value if the item is there now. Otherwise it's
what was cleared when the item last moved forward out of that stage. The dedupe is per field, so a
departure that clears only `protein_g` replaces only that stage's protein, and the stage's earlier
`weight_lbs` snapshot stays in force.

**Why dedupe.** Without it (round 1), every forward crossing out of a stage added its own snapshot.
Example: Breakfast → Brunch (snapshot 30), back to Breakfast, correct the value to 35, then
Breakfast → Brunch again (snapshot 35). Round 1 counted 30 + 35. Now only 35 counts.

**Key on `from_stage_id`, not `to_stage_id`.** I'm deliberately departing from the sanity-check's
literal wording here. Its own intent was "the value the last time the item *left this particular
stage*", and the stage being left is `from_stage_id`. The difference shows up because
Nutrition allows forward skips (Section 0.1). Example: breakfast → lunch, back, then
breakfast → brunch. Both departures carry breakfast's values but have different `to_stage_id`s.
Keying on `to_stage_id` would count both, which is the same double count, reached by a different
path. Step 4's check includes exactly this case and distinguishes the two keyings (60 vs 75).

**Live value keyed to the current stage, and allowed to supersede that stage's snapshot.** Example:
an item went Brunch → Lunch (Brunch snapshot taken), then back to Brunch, where the user corrects
Brunch. The live value is Brunch's latest. Counting it *alongside* the old Brunch snapshot would
re-create the double count.

**Residual limitation (pre-existing move_stage behaviour, not introduced here).** Backward moves
neither clear nor restore. So landing on Breakfast from Lunch shows *Lunch's* numbers under
Breakfast, and in the item's own stage view that is Breakfast's value from then on. The report
follows the stage view:

- **Backed out and edited (the correction case).** The report is correct.
- **Backed out and moved forward again without editing.** The carried-over values replace the
  earlier stage's original snapshot. Today's stage UI loses the same data the same way: the stage
  you came back to shows empty. Round 1's sum-everything rule didn't fix this either; it
  double-counted it instead.

A complete fix belongs on the write side, and I've deliberately deferred it as a follow-up for the
architect. The idea: a backward move would also snapshot and clear the departing stage's shared
keys, and an arrival would restore that stage's last snapshot into `data`. Then `item.data` always
equals "this stage's last values", and the read rule above is exact in every case. It isn't done
here because:

- it changes what users see when they go back a stage (their earlier numbers reappear instead of
  the later stage's);
- it means a fifth redefinition of `move_stage`;
- the review rounds explicitly accepted the write side as designed.

**Rejected alternatives (unchanged from round 1):**
- *Deriving pre-clear values on read by replaying `data_changed` events.* It needs a more complex
  query, it re-interprets history whenever a checklist is edited, and it can't tell moves made
  before `20261113000000` from moves made after.
- *Per-stage namespaced keys.* They would break the shared-checklist design.
- *A separate snapshot table.* `item_events.data` on `stage_changed` already exists and is unused.

### D2. No backfill of historical events

Only `a831e45f` has ever moved forward. Its moves came minutes after `20261113000000` was committed,
and there's no record of when that migration was pushed. Its events carry no `cleared` data either
way, so local 2026-11-12 reports dinner's live values only. This is stated in the migration
comment. A hand correction is out of scope.

### D3. Config is one `workflows.report_config jsonb` column

```json
{
  "period": "day",
  "show_count": false,
  "fields": [
    {"key": "protein_g", "label": "Protein", "unit": "g", "agg": "sum", "goal_direction": "at_least"},
    {"key": "weight_lbs", "label": "Weight", "unit": "lbs", "agg": "last", "goal_direction": "at_most"}
  ]
}
```

| property | values | default | notes |
|---|---|---|---|
| `period` | `day`, `week`, `month` | **required** (CHECK-enforced) | Weeks are ISO, Monday start, matching Postgres `date_trunc('week')`. |
| `fields` | array | **required** (CHECK-enforced) | |
| `show_count` | boolean | `false` | Items per period. That's throughput for the mechanic and noise for nutrition. |
| `fields[].key` | any `data.*` key | required (client and RPC skip entries without one) | |
| `fields[].agg` | `sum`, `avg`, `last` | `sum` | Applied twice: across an item's per-stage values, then across the items in a period. |
| `fields[].label` | text | the key, humanized | |
| `fields[].unit` | text | none | No fallback to the `_g`/`_lbs` suffix convention. |
| `fields[].unit_position` | `prefix`, `suffix` | `suffix` | Lets the mechanic's `$` render as `$500`. |
| `fields[].goal_direction` | `at_least`, `at_most` | `at_least` | A property of the field, not of the goal row. |

**Why a jsonb column on `workflows` (accepted in review, unchanged):**
- `checklist` set the precedent of static, migration-authored metadata stored as jsonb.
- A report spans stages, so it belongs on the workflow.
- A nullable column doubles as the on/off switch.

**Rejected:**
- *A `report_fields` child table.* More DDL and RLS for rows nobody edits.
- *Hints on `stages.checklist` entries.* That would break every reader of `checklist`.

### D4. Goals are dated, append-only rows in `report_goals`

**Chosen.** `report_goals(workflow_id, field_key, target numeric null check (target >= 0),
effective_from date, created_by, created_at)`.
- A goal applies from `effective_from` until a later row for the same field supersedes it.
- `target = null` means "no goal from this date".
- There's no UPDATE or DELETE. For the same `effective_from`, the latest `created_at` wins.
- **New in round 2:** `target >= 0`. A negative goal is meaningless for every field this shape can
  describe, and the constraint lets the client's progress maths assume `target >= 0` (Step 6c).

**Why dated:**
- A static goal would rewrite past periods' met/missed status.
- Goals are user-edited, while config is migration-authored.
- It costs one small table.

**Rejected:**
- *A static goal in `report_config`.*
- *Goals as items in a separate "Goals" workflow.* That couples workflows to each other, and you
  can't back-date an item.
- *Goals as a stage.* See Section 0.5.

**Goal-in-effect rule.** A period's goal is the one in effect on the period's **last day**, or
**today** if the period is still in progress. The alternative, "in effect on the first day", is
flagged for reviewers.

Goals are per period: 150 on a `day` report means 150 per day. That's why `period` is set-once.

### D5. Grouping: an item belongs to the period containing its `created_at`, in the viewer's timezone

- `period_start = date_trunc(period, created_at AT TIME ZONE p_tz)`.
- The client passes `p_tz`, taken from `Intl.DateTimeFormat().resolvedOptions().timeZone` through a
  3-line JS helper.
- Rejected: a per-workflow timezone.
- Rejected: `TimeZoneInfo.Local.Id`.
- Known gap, deliberately deferred: the mechanic's revenue might be better bucketed by when the job
  was invoiced (`date_anchor: "terminal"`).
- **Consistency fix (Step 6b).** `ItemDisplayName` switches to `item.CreatedAt.ToLocalTime()`, so the
  list and the report agree on which day `a831e45f` belongs to.

### D6. Aggregation runs server-side in one RPC

- `report_series(p_workflow_id, p_from, p_to, p_tz)` returns
  `(period_start date, item_count bigint, field_values jsonb)`, one row per non-empty period.
- It runs as security invoker, with RLS scoping it like `search_items`.
- Values are coerced to numbers by `private.jsonb_numeric`:
  - numbers pass through;
  - `"$1,250.00"`-style strings are parsed;
  - anything else becomes null.
- Rejected: client-side aggregation. It would mean N+1 requests over all history.

### D7. UI: one generic page; inline SVG, no chart library

- The page is `WorkflowReport.razor`.
- It uses only Fluent components already proven in `WorkflowDetail` under Fluent UI Blazor
  v5.0.1: `FluentCard`, `FluentStack`, `FluentButton`, `FluentLink`, `FluentSpinner`,
  `FluentMessageBar`.
- Inputs are plain HTML `<input>`.
- Progress bars are plain divs; charts are inline SVG.
- Colours come only from the tokens in Section 0.4.

### D8. The agent loop is untouched

Chat access to report numbers is out of scope.

## 3. Steps

### Step 1. Migration: `move_stage` snapshots what it clears

File: `supabase/migrations/20261115000000_move_stage_records_cleared_values.sql`

**Copy the full current body from `20261113000000_move_stage_clears_shared_fields.sql` and change
only the marked lines.** `20261016130000` once silently dropped the enforce-stage-order check while
rewriting this function. Step 4 diffs the new body against the old one before pushing.

```sql
-- move_stage: record the values it clears in the stage_changed event itself (2026-11-15).
-- Since 20261113000000, a forward move deletes checklist keys shared by the departing and
-- arriving stages (every Nutrition Tracker meal stage reuses protein_g/carbs_g/...), so once a
-- day's item reaches Brunch, Breakfast's totals exist nowhere but as "the last data_changed patch
-- before the move" -- recoverable only by replaying events against today's checklists, which
-- can't tell history apart from later checklist edits. The generic Report (plans/generic-report-
-- feature/) needs each stage's final values, so the move that discards them now writes them down
-- at the moment it happens. data stays null when nothing is cleared, so workflows without shared
-- keys (the mechanic, Feature Pipeline) log exactly what they did before.
-- A later forward move out of the same stage (after going back to correct it) writes a second
-- snapshot; readers must treat the latest snapshot per (item, from_stage_id, key) as that stage's
-- value, not add them up -- report_series (20261115010000) does exactly that.
-- No backfill: the only Nutrition item that has ever moved forward is one test-like day whose
-- moves straddle 20261113000000's rollout, so what those moves actually cleared is unknowable --
-- see the plan's D2. That day reports its live (dinner) values only.

create or replace function public.move_stage(p_item_id uuid, p_to_stage_id uuid)
returns public.items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  -- ... every declaration from 20261113000000, plus:
  v_cleared jsonb;   -- NEW
begin
  -- ... unchanged from 20261113000000 up to and including the v_shared_keys computation ...

  -- NEW: capture before the update below deletes them. Only keys actually present -- a shared key
  -- with no value at the departing stage contributes nothing.
  select jsonb_object_agg(k, v_item.data -> k) into v_cleared
  from unnest(coalesce(v_shared_keys, array[]::text[])) as k
  where v_item.data ? k;

  -- ... the UPDATE public.items exactly as in 20261113000000 ...

  insert into public.item_events (item_id, event_type, from_stage_id, to_stage_id, stage_id, data)
  values (p_item_id, 'item.stage_changed', v_from_stage, p_to_stage_id, p_to_stage_id,
          case when v_cleared is not null then jsonb_build_object('cleared', v_cleared) end);  -- CHANGED

  return v_item;
end;
$$;
```

Notes (confirmed in review):
- `v_item` still holds the pre-update row at the capture point.
- `jsonb_object_agg` over zero rows returns null.
- Nothing reads `stage_changed.data` today.

### Step 2. Migration: report config, numeric helper, RPC, Nutrition content

File: `supabase/migrations/20261115010000_add_workflow_report_config.sql`

```sql
-- Generic per-workflow Report (2026-11-15). The user wanted daily macro totals, goal comparison and
-- a trend for Nutrition Tracker, but explicitly not a Nutrition-only dashboard -- so, like
-- stages.checklist, which fields matter and how is per-workflow jsonb config read by one generic
-- page, not code. A jsonb column rather than a child table for the same reason checklist is one
-- (20261104020000): static, migration-authored metadata read wholesale, with no identity of its
-- own. On workflows, not stages, because a report spans stages (a day's protein is breakfast +
-- ... + dinner). null = this workflow has no report (and the UI shows no Report link).
-- "period" fixes what a goal's number means (per day / week / month) -- changing it later
-- silently reinterprets existing report_goals rows, so treat it as set-once.
--
-- The CHECK is written so that no conjunct can evaluate to NULL for a non-null report_config:
-- a CHECK passes on NULL as well as TRUE, so a bare report_config->>'period' in (...) would
-- wrongly accept a config with no "period" key at all. ?& / coalesce / jsonb_typeof of a non-null
-- value are all strictly true/false.

alter table public.workflows
  add column report_config jsonb
  constraint workflows_report_config_shape check (
    report_config is null or (
      jsonb_typeof(report_config) = 'object'
      and report_config ?& array['period', 'fields']
      and coalesce(report_config ->> 'period', '') in ('day', 'week', 'month')
      and coalesce(jsonb_typeof(report_config -> 'fields'), '') = 'array'
    )
  );

-- Report values come from free-form item.data, which the agent writes; today every reported value
-- is a JSON number, but a "$1,250" string from chat shouldn't silently zero a revenue report.
-- Unparseable -> null -> ignored. In private (not exposed as an RPC) like the access helpers;
-- invoker rights, since it touches no tables.
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
-- containing its created_at in the caller's timezone -- there is no day-level container item
-- anywhere in this engine, and the browser's local day is what the user means by "today" (a
-- 21:53 Central entry is not tomorrow's).
-- An item's value for a field is built per STAGE the item has been at: the value that field held
-- the last time the item was at that stage -- its live data value if it's there now, else what
-- move_stage cleared on the most recent forward move OUT of that stage (20261115000000). Deduping
-- per (item, from_stage, key) to the latest seq is what stops a back-up-and-correct from being
-- added on top of the original snapshot instead of replacing it. Keyed on from_stage_id (the stage
-- the values belonged to), not to_stage_id: Nutrition allows forward skips, so two departures from
-- the same stage can land on different stages. Those per-stage values are then combined with the
-- field's agg (a Nutrition day sums its meals; a mechanic job, which never clears anything, is
-- just its live data).
-- security invoker: RLS on workflows/items/item_events scopes rows, same as search_items.
create function public.report_series(p_workflow_id uuid, p_from date, p_to date, p_tz text default 'UTC')
returns table (period_start date, item_count bigint, field_values jsonb)
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
  fields as (
    select f->>'key' as key, coalesce(f->>'agg', 'sum') as agg
    from cfg, jsonb_array_elements(cfg.c->'fields') as f
    where f->>'key' is not null
  ),
  its as (
    select i.id, i.stage_id, i.data, i.created_at,
      case cfg.c->>'period'
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
    select its.id as item_id, its.stage_id, f.key, f.agg,
           private.jsonb_numeric(its.data -> f.key) as v,
           9223372036854775807::bigint as seq
    from its cross join fields f
    where its.data ? f.key
    union all
    -- cleared snapshots: attributed to the stage the item was leaving
    select e.item_id, e.from_stage_id, f.key, f.agg,
           private.jsonb_numeric(e.data -> 'cleared' -> f.key), e.seq
    from public.item_events e
    join its on its.id = e.item_id
    cross join fields f
    where e.event_type = 'item.stage_changed' and e.data -> 'cleared' ? f.key
  ),
  segments as (
    -- one value per (item, stage, field): the latest
    select distinct on (r.item_id, r.stage_id, r.key) r.item_id, r.stage_id, r.key, r.agg, r.v, r.seq
    from raw_segments r
    order by r.item_id, r.stage_id, r.key, r.seq desc
  ),
  item_vals as (
    select s.item_id, s.key, s.agg,
      case s.agg
        when 'sum'  then sum(s.v)
        when 'avg'  then avg(s.v)
        when 'last' then (array_agg(s.v order by s.seq desc) filter (where s.v is not null))[1]
      end as v
    from segments s
    group by s.item_id, s.key, s.agg
  ),
  period_vals as (
    select its.period_start, iv.key,
      case iv.agg
        when 'sum'  then sum(iv.v)
        when 'avg'  then avg(iv.v)
        when 'last' then (array_agg(iv.v order by its.created_at desc) filter (where iv.v is not null))[1]
      end as v
    from item_vals iv
    join its on its.id = iv.item_id
    group by its.period_start, iv.key, iv.agg
  )
  select p.period_start,
         count(*) as item_count,
         coalesce((select jsonb_object_agg(pv.key, pv.v)
                   from period_vals pv
                   where pv.period_start = p.period_start and pv.v is not null), '{}'::jsonb)
  from its p
  group by p.period_start
  order by p.period_start;
$$;
revoke all on function public.report_series(uuid, date, date, text) from public;
grant execute on function public.report_series(uuid, date, date, text) to authenticated;

-- Nutrition Tracker's report. Matched by name since ids differ between dev and prod (same pattern
-- as 20261112000000). weight_lbs is a reading, not an amount, hence "last" not "sum".
update public.workflows
set report_config = '{
  "period": "day",
  "fields": [
    {"key": "protein_g",  "label": "Protein", "unit": "g",   "agg": "sum",  "goal_direction": "at_least"},
    {"key": "carbs_g",    "label": "Carbs",   "unit": "g",   "agg": "sum",  "goal_direction": "at_most"},
    {"key": "fat_g",      "label": "Fat",     "unit": "g",   "agg": "sum",  "goal_direction": "at_most"},
    {"key": "fiber_g",    "label": "Fiber",   "unit": "g",   "agg": "sum",  "goal_direction": "at_least"},
    {"key": "sugar_g",    "label": "Sugar",   "unit": "g",   "agg": "sum",  "goal_direction": "at_most"},
    {"key": "weight_lbs", "label": "Weight",  "unit": "lbs", "agg": "last", "goal_direction": "at_most"}
  ]
}'::jsonb
where name = 'Nutrition Tracker' and report_config is null;
```

Notes:
- **CHECK.** With `report_config` non-null, every conjunct is a strict boolean:
  - `jsonb_typeof` of a non-null value is never null;
  - `?&` returns true or false;
  - both `coalesce`s map a missing key to `''`.

  `AND` doesn't guarantee short-circuit evaluation. That's harmless here: `->>`/`->` with a text key
  on a jsonb array or scalar return null rather than erroring, and the `coalesce`s absorb that null.
  Per-field shape (each field has a string `key`, `agg` is known) is deliberately **not** in the
  CHECK; the `jsonb_path` expression it would need is easy to get subtly wrong. Instead:
  - `report_series` filters out key-less fields (`where f->>'key' is not null`). Without that filter
    a null key could reach `jsonb_object_agg`, which errors on null keys.
  - An unknown `agg` makes the `case` yield null, so that field shows "—".
  - The client parser skips fields with no key or an unknown `agg` (Step 5).
- **`distinct on` with a null `stage_id`.** `from_stage_id` is never null on `stage_changed` events,
  because an item always has a stage. If it ever were, `distinct on` treats nulls as equal, which
  is still a sane grouping.
- **Index coverage.** `items(workflow_id)` and `item_events(item_id, seq)` are enough at these
  volumes.
- **Content to confirm with the user.** Carbs and fat as `at_most` is a reasonable default, not
  something the user said (Section 4).

### Step 3. Migration: `report_goals`

File: `supabase/migrations/20261115020000_add_report_goals.sql`

```sql
-- Dated report goals (2026-11-15). A goal is user data that changes on the user's schedule
-- (cutting/bulking, a slow month), and a past period's met/missed must not be rewritten when it
-- does -- so goals are dated rows that apply from effective_from until superseded, not one static
-- number in workflows.report_config. Deliberately NOT items/stages: the superseded diet design's
-- "nutrition_goal" stage couldn't coexist with the shipped sequential workflow's single
-- is_initial stage, and goals aren't daily-recurring entries anyway (20261112000000). target null =
-- "no goal from this date"; target >= 0 otherwise (a negative goal means nothing for any field this
-- report can describe, and the UI's progress maths relies on it). Append-only like
-- item_events/agent_events: a correction is a new row (latest created_at wins for the same
-- effective_from). field_key is not FK-checked against report_config -- it's jsonb -- the UI only
-- offers configured fields.

create table public.report_goals (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null references public.workflows (id),
  field_key text not null,
  target numeric check (target is null or target >= 0),
  effective_from date not null,
  created_by uuid not null default auth.uid() references auth.users (id),
  created_at timestamptz not null default now()
);

create index on public.report_goals (workflow_id, field_key, effective_from desc, created_at desc);

alter table public.report_goals enable row level security;

create policy report_goals_select on public.report_goals
  for select to authenticated
  using (private.can_access_workflow(workflow_id));

create policy report_goals_insert on public.report_goals
  for insert to authenticated
  with check (private.can_access_workflow(workflow_id) and created_by = auth.uid());

-- Required explicitly: default privileges on public tables were revoked from authenticated
-- (2026-11-09, see PROGRESS.md), so a new table starts with no grants at all.
grant select, insert on public.report_goals to authenticated;
```

(The `target` CHECK here is NULL-safe on purpose. `target is null` is its own explicit, accepted
case, and when `target` is non-null the comparison is strictly true or false.)

### Step 4. Push and verify the database side

```bash
cd /home/mmcbride/micah/claude/workflow-app
diff <(sed -n '/create or replace function/,$p' supabase/migrations/20261113000000_move_stage_clears_shared_fields.sql) \
     <(sed -n '/create or replace function/,$p' supabase/migrations/20261115000000_move_stage_records_cleared_values.sql)
# expect ONLY: the v_cleared declaration, the jsonb_object_agg block, and the insert's data column
supabase db push --linked --dry-run   # expect exactly the three new files
supabase db push --linked
```

**4a. Read-only check against real data.**

```bash
supabase db query --linked "select * from public.report_series(
  (select id from public.workflows where name = 'Nutrition Tracker'),
  '2026-11-10', '2026-11-16', 'America/Chicago')"
```

Expect exactly 4 rows: 11-12, 11-13, 11-14 and 11-15. Each has `item_count` 1 and `field_values`
equal to that item's live macros (Section 0.1):
- 11-12: protein 38 (`a831e45f`'s dinner values; D2);
- 11-13: protein 90;
- 11-14: protein 45;
- 11-15: protein 52.

Re-run with `'UTC'` and expect 3 rows, with 11-13's `item_count` = 2.

**4b. Write-path checks: one self-rolling-back `DO` block** (mechanism in Section 0.2).

Save it as `scripts/report_series_dev_check.sql` and commit it with Step 9, since it can safely be
re-run. Run it with `supabase db query --linked -f scripts/report_series_dev_check.sql`.

**Expected output:** an error whose message starts with `PASS`. Anything starting with `FAIL` or
`SETUP`, or any other error, is a failure. Either way, nothing persists.

```sql
-- Report write-path checks against dev. ALWAYS ends in an exception so every write below is
-- rolled back; success is an error message beginning 'PASS'. Safe to re-run.
do $$
declare
  v_tz   text := 'America/Chicago';
  v_day  date := (now() at time zone 'America/Chicago')::date;
  v_wf   uuid; v_uid uuid;
  v_b uuid; v_br uuid; v_l uuid;
  v_id   uuid;
  v_base numeric; v_p numeric; v_w numeric; v_ev jsonb;
  v_mech uuid; v_m_to uuid; v_mid uuid;
  v_fp uuid; v_fp_skip uuid; v_fpid uuid; v_fp_note text := 'no enforce_stage_order workflow visible; relied on Step 4 diff';
begin
  ---------------------------------------------------------------- setup (as the CLI's role)
  select id into v_wf from public.workflows where name = 'Nutrition Tracker';
  -- Nutrition Tracker's account owner (same account as Joe's Auto Repair, Section 0.1)
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
  select id into v_b  from public.stages where workflow_id = v_wf and title = 'breakfast';
  select id into v_br from public.stages where workflow_id = v_wf and title = 'brunch';
  select id into v_l  from public.stages where workflow_id = v_wf and title = 'lunch';

  ---------------------------------------------------------------- 1. CHECK constraint (as CLI role)
  begin
    update public.workflows set report_config = '{"period": "day"}' where id = v_wf;
    raise exception 'FAIL check: config without "fields" accepted';
  exception when check_violation then null; end;
  begin
    update public.workflows set report_config = '{"fields": []}' where id = v_wf;
    raise exception 'FAIL check: config without "period" accepted';
  exception when check_violation then null; end;
  begin
    update public.workflows set report_config = '{"period": "year", "fields": []}' where id = v_wf;
    raise exception 'FAIL check: unknown period accepted';
  exception when check_violation then null; end;
  begin
    update public.workflows set report_config = '[]' where id = v_wf;
    raise exception 'FAIL check: non-object config accepted';
  exception when check_violation then null; end;

  ---------------------------------------------------------------- become the real user
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- today's real item(s) may already hold protein; measure deltas against this baseline
  select (field_values ->> 'protein_g')::numeric into v_base
  from public.report_series(v_wf, v_day, v_day, v_tz);
  v_base := coalesce(v_base, 0);

  select id into v_id from public.create_item(v_wf, '{}'::jsonb);   -- lands on breakfast

  ---------------------------------------------------------------- 2. snapshot + simple total
  perform public.update_data(v_id, '{"protein_g": 30, "weight_lbs": 180}');
  perform public.move_stage(v_id, v_br);
  select data into v_ev from public.item_events
  where item_id = v_id and event_type = 'item.stage_changed' order by seq desc limit 1;
  if v_ev is distinct from '{"cleared": {"protein_g": 30, "weight_lbs": 180}}'::jsonb then
    raise exception 'FAIL snapshot: %', v_ev;
  end if;
  perform public.update_data(v_id, '{"protein_g": 20}');
  select (field_values ->> 'protein_g')::numeric, (field_values ->> 'weight_lbs')::numeric
    into v_p, v_w from public.report_series(v_wf, v_day, v_day, v_tz);
  -- "is distinct from", not "<>": a null result must FAIL, not slip through
  if (v_p - v_base) is distinct from 50 or v_w is distinct from 180 then
    raise exception 'FAIL simple: protein delta % (want 50), weight % (want 180)', v_p - v_base, v_w;
  end if;

  ---------------------------------------------------------------- 3. back up, correct, forward again
  perform public.move_stage(v_id, v_b);                       -- backward: clears nothing
  perform public.update_data(v_id, '{"protein_g": 35}');       -- corrected breakfast
  perform public.move_stage(v_id, v_br);                      -- 2nd breakfast snapshot: 35
  perform public.update_data(v_id, '{"protein_g": 20}');       -- brunch again
  select (field_values ->> 'protein_g')::numeric, (field_values ->> 'weight_lbs')::numeric
    into v_p, v_w from public.report_series(v_wf, v_day, v_day, v_tz);
  -- 35 + 20; round 1's sum-everything would give 30 + 35 + 20 = 85.
  -- weight stays 180: the 2nd breakfast departure didn't carry weight, so per-field dedupe
  -- keeps the 1st breakfast snapshot's weight.
  if (v_p - v_base) is distinct from 55 or v_w is distinct from 180 then
    raise exception 'FAIL correction: protein delta % (want 55), weight % (want 180)', v_p - v_base, v_w;
  end if;

  ---------------------------------------------------------------- 4. forward skip out of the same stage
  perform public.move_stage(v_id, v_l);                       -- brunch snapshot: 20
  perform public.move_stage(v_id, v_b);                       -- backward, data now empty
  perform public.update_data(v_id, '{"protein_g": 40}');
  perform public.move_stage(v_id, v_l);                       -- skip breakfast -> lunch, snapshot 40
  select (field_values ->> 'protein_g')::numeric into v_p
  from public.report_series(v_wf, v_day, v_day, v_tz);
  -- from_stage keying: breakfast 40 + brunch 20 = 60. to_stage keying would give
  -- brunch-arrivals 35 + lunch-arrivals 40 = 75; no dedupe would give 125.
  if (v_p - v_base) is distinct from 60 then
    raise exception 'FAIL skip: protein delta % (want 60)', v_p - v_base;
  end if;

  ---------------------------------------------------------------- 5. mechanic: no shared keys -> data null
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

  ---------------------------------------------------------------- 6. enforce_stage_order still enforced (if reachable)
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

  raise exception 'PASS (all rolled back): snapshot ok, totals 50/55/60 over baseline %, mechanic data null, enforce: %',
    v_base, v_fp_note;
end;
$$;
```

Notes on this block:
- **Why per-check failure messages.** Each `FAIL …` names its check and prints the actual values,
  because a failure aborts the block and nothing after it runs.
- **Nested `exception when …` blocks.** Each one rolls back only its own subtransaction, so the
  CHECK probes leave nothing behind even before the final raise.
- **The FAIL raise inside a probe isn't swallowed.** In the CHECK probes, `raise exception 'FAIL …'`
  has SQLSTATE P0001, which the `check_violation` handler doesn't catch, so it propagates.
- **The same holds for the enforce probe.** In check 6, the handler re-raises anything whose
  message isn't `forward skip…`, including the block's own `FAIL enforce` exception.
- **The CHECK probes run before the role switch**, as the CLI's role. That role owns the tables, so
  the probes don't depend on `workflows_update` RLS.
- **Feature Pipeline's real coverage is local.** `scripts/phase3_sdlc_order_test.py` is local-stack
  only (Section 0.2). Check 6 covers dev only if the owner can see an enforce-ordered workflow.
  The PASS message says which happened.
- **Fallback if `set local role authenticated` is refused inside a `DO` block via the Management
  API** (Section 4): paste the same file into the dashboard SQL editor. If that fails too, Step 8's
  UI check 4 covers checks 2 and 3 for real (not rolled back, on a real day).

### Step 5. Client API (`web/Services/WorkflowApiClient.cs`)

**New records:**

```csharp
// Generic Report (2026-11-15) -- parsed from workflows.report_config; see
// 20261115010000_add_workflow_report_config.sql for the shape and why it's jsonb on workflows.
public record ReportField(string Key, string Label, string Unit, bool UnitPrefix, string Agg, bool GoalAtMost);
public record ReportConfig(string Period, bool ShowCount, List<ReportField> Fields);
public record ReportPeriodRow(DateOnly PeriodStart, long ItemCount, Dictionary<string, double> Values);
public record ReportGoal(string FieldKey, double? Target, DateOnly EffectiveFrom, DateTimeOffset CreatedAt);
```

**Changed:** `WorkflowSummary` gets a trailing optional parameter:
`public record WorkflowSummary(string Id, string Name, string ItemLabel, ReportConfig? Report = null);`.
- `GetWorkflowAsync` adds `report_config` to its `select` and parses it with a private
  `ParseReportConfig(JsonNode?)`.
- `ParseReportConfig` returns null on a null node. It skips fields missing `key` or with an `agg`
  other than `sum`/`avg`/`last`.
- `GetWorkflowsAsync` is unchanged; its 3-argument construction still compiles.

**New methods:**
- `GetReportSeriesAsync(string workflowId, DateOnly from, DateOnly to, string tz)`: POST
  `/rest/v1/rpc/report_series`, same pattern as `SearchItemsAsync`. Dates are sent as `yyyy-MM-dd`.
- `GetReportGoalsAsync(string workflowId)`: GET
  `/rest/v1/report_goals?workflow_id=eq.{id}&select=field_key,target,effective_from,created_at&order=effective_from.asc,created_at.asc`.
- `AddReportGoalAsync(string workflowId, string fieldKey, double? target, DateOnly effectiveFrom)`:
  POST `/rest/v1/report_goals`, same pattern as `AddChatMessageAsync`. `created_by` comes from its
  default.

### Step 6. UI

**6a. `web/wwwroot/js/timezone.js` (new).**
`window.getTimeZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone;`. Load it with
`<script src="js/timezone.js"></script>` next to `focus.js` in `index.html`.

**6b. `WorkflowDetail.razor`, two small edits:**
- In the list view, after the Show/Hide closed link, add:
  `@if (_workflow?.Report is not null) { <FluentLink Href="@($"workflow/{WorkflowId}/report")" Class="back-link" Style="margin-left:16px;">Report</FluentLink> }`.
  The `Href` is relative, so the Pages subpath and `404.html` redirect apply unchanged.
- In `ItemDisplayName`, change `{item.CreatedAt:yyyy-MM-dd}` to
  `{item.CreatedAt.ToLocalTime():yyyy-MM-dd}`.

**6c. `web/Pages/WorkflowReport.razor` (new).**

`@page "/workflow/{WorkflowId}/report"`. Injects `WorkflowApiClient` and `IJSRuntime`, and adds
`@using System.Globalization` for `ISOWeek`.

**Period arithmetic.** These are pure static helpers on `DateOnly`. They must match the RPC's
`date_trunc` exactly.

```csharp
static DateOnly PeriodStart(string period, DateOnly d) => period switch
{
    "day"   => d,
    // ISO week = Monday start, identical to Postgres date_trunc('week', ...), including across
    // year boundaries (2027-01-01, a Friday, -> 2026-12-28).
    "week"  => DateOnly.FromDateTime(ISOWeek.ToDateTime(
                   ISOWeek.GetYear(d.ToDateTime(TimeOnly.MinValue)),
                   ISOWeek.GetWeekOfYear(d.ToDateTime(TimeOnly.MinValue)),
                   DayOfWeek.Monday)),
    "month" => new DateOnly(d.Year, d.Month, 1),   // = date_trunc('month', ...)
    _ => d,
};

static DateOnly NextPeriod(string period, DateOnly p) => period switch
{
    "day"   => p.AddDays(1),
    "week"  => p.AddDays(7),      // p is always a Monday; DateOnly has no DST, so +7 is exact
    "month" => p.AddMonths(1),    // p is always the 1st, so AddMonths never clamps (no Jan 31 -> Feb 28 drift)
    _ => p.AddDays(1),
};

static DateOnly AddPeriods(string period, DateOnly p, int n) => period switch
{
    "day"   => p.AddDays(n),
    "week"  => p.AddDays(7 * n),
    "month" => p.AddMonths(n),
    _ => p.AddDays(n),
};
```

**Load sequence:**
1. Call `GetWorkflowAsync`. If `Report` is null, show "This workflow has no report configured." with
   a back link.
2. `tz = await JS.InvokeAsync<string>("getTimeZone")`, falling back to `"UTC"` on exception.
3. `today = DateOnly.FromDateTime(DateTime.Now)`. In WASM, `DateTime.Now` uses the browser's zone,
   which Notes timestamps already rely on.
4. **Range from the selected chip.** A chip of N means **N periods, the last one being the current
   (partial) period**:
   - `current = PeriodStart(period, today)`
   - `from = AddPeriods(period, current, -(N - 1))`
   - `to = today`

   | period | chips (N) | default |
   |---|---|---|
   | `day` | 7 / 30 / 90 | 7 |
   | `week` | 8 / 26 / 52 | 8 |
   | `month` | 6 / 12 / 24 | 6 |

   Examples:
   - `week`, N=8, today Sun 2026-11-15: `current = 2026-11-09` (Mon), `from = 2026-09-21`.
   - `month`, N=6, today 2026-11-15: `from = 2026-06-01`.

   Because `from` is always a period start, every period in the range is complete on the server
   side. No period is cut in half by the `between p_from and p_to` filter.
5. Call `GetReportSeriesAsync` and `GetReportGoalsAsync` in parallel (`Task.WhenAll`).
6. Build the period list: `p = from; while (p <= today) { yield p; p = NextPeriod(period, p); }`.
   It always has exactly N entries. Join it to the rows on `PeriodStart`. **A missing period means
   "no data" (shown as —), not 0.**

**Rendering**, top to bottom, single column, phone-first:
- **Header.** Back link `← {ItemLabelPlural}` to `workflow/{WorkflowId}`, then
  `ThemeToggleButton`, then `<h1>{workflow.Name} report</h1>`.
- **Range chips.** Three `FluentButton`s. The selected one is
  `Appearance="ButtonAppearance.Primary"`; the others take the default appearance used by
  `WorkflowDetail`'s non-primary buttons.
- **One `FluentCard` per configured field:**
  - **Title line.** The label, the current period's value with its unit ("52g", "$500"), and the
    current period's name ("Today" / "This week" / "This month").
  - **Goal block**, shown if a goal is in effect for the current period (`GoalFor` below returns
    non-null). Written ≥ for `at_least` and ≤ for `at_most`: "of ≥150g" / "of ≤50g". Below that,
    a plain-div progress bar.
    - **Track:** `background:var(--colorNeutralBackground3, #e0e0e0)`; height 8px;
      `border-radius:var(--app-radius)`.
    - **Fill width** is `fraction` (see below).
    - **Fill colour and status text by direction.** The two directions deliberately read
      differently at a glance. A full green bar is good; a red bar is bad.

      | direction | state | fill | status text |
      |---|---|---|---|
      | `at_least` | `value < target` | `var(--app-accent)` | "98g to go" |
      | `at_least` | `value >= target` | `var(--colorPaletteGreenForeground1, #107c10)` | "Met" |
      | `at_most` | `value <= target` | `var(--app-accent)` | "12g left" (or "At limit" when equal) |
      | `at_most` | `value > target` | `var(--colorPaletteRedForeground1, #c00)`, full width | "12g over" |

      The red token and its fallback are the ones `WorkflowDetail` already uses for scan errors.
      The green token follows the same Fluent-token-plus-hex-fallback convention. If the token
      name doesn't resolve under Fluent UI Blazor v5, the fallback renders, so a wrong guess
      can't break anything.
    - **`fraction`**, with every case defined (no 0/0):

      ```csharp
      static double Fraction(double value, double target, bool atMost) =>
          target > 0 ? Math.Clamp(value / target, 0, 1)
          : value > 0 ? 1                       // target 0, something logged: at_least met / at_most over
          : atMost ? 0 : 1;                     // target 0, nothing logged: at_most "Met" empty, at_least met full
      ```

      `target >= 0` is guaranteed by the `report_goals` CHECK (Step 3), so negatives can't occur.
      For `at_most` with target 0 and value 0, the status is "Met".
  - **Range summary**, computed over the **completed** periods only (the N−1 before the current
    one). Including the in-progress period would count a half-eaten day as a missed protein goal
    and drag the average down. Labelled "Previous 6 days" (or N−1 weeks / months):
    - the average over periods *with data*;
    - "Goal met on N of M", where M counts periods that had both data and a non-null goal.
  - **Trend.** An inline `<svg viewBox="0 0 {N*10} 80" preserveAspectRatio="none">`, width 100%,
    height 80px.
    - One bar per period with data. No bar for periods without data. The current period's bar is at
      `opacity:0.5` to mark it as partial.
    - Bars use `fill:var(--app-accent)`.
    - Scale = max(value, goal) over the range. **If that max is 0 or there's no data, draw only the
      baseline** (no divide-by-zero).
    - The goal is a polyline step at each period's own goal, using
      `stroke:var(--colorNeutralForeground2, #616161)` with `stroke-dasharray`.
    - Each bar has a `<title>` with the date and value.
    - For `agg == "last"`, draw a polyline of points instead of bars, chosen by `agg` and not by
      field name.
  - **"Set goal" link.** Opens an inline form:
    - `<input type=number step=any min=0>` for the target;
    - `<input type=date>` defaulting to today;
    - Save, and "Remove goal" (which saves `target = null`).

    The client rejects a negative or empty target before calling (Remove is the explicit null path).
    On save, it calls `AddReportGoalAsync` and reloads goals only. Save is disabled while saving.
    Errors appear inline in `color:var(--colorPaletteRedForeground1, #c00)`, the same style as the
    scan error lines.
- **Period list.** Collapsed behind a "Show each day/week/month" link, newest first:
  `Nov 15 — Protein 52g · Carbs 55.5g · …`. It appends `· {count} {ItemLabelPlural}` when
  `ShowCount` is set. With `ShowCount`, there's also an "{ItemLabelPlural} this period" card, using
  the same rendering with no goal.

**Goal resolution.** `GoalFor(fieldKey, DateOnly periodStart) → double?` works in two steps:
1. Compute `asOf = min(NextPeriod(period, periodStart).AddDays(-1), today)`.
2. Pick the last goal for that field with `EffectiveFrom <= asOf`, ordered by
   `(EffectiveFrom, CreatedAt)`, and return its `Target`. That may be null.

**Number formatting.** `0.#` for values, with no thousands grouping for `g`. The `$` prefix uses
`N0` when the value is whole and `N2` otherwise. Invariant culture.

### Step 7. Mechanic dry run (kept; a self-rolling-back `DO` block)

Save as `scripts/report_mechanic_dry_run.sql` and run with
`supabase db query --linked -f scripts/report_mechanic_dry_run.sql`. **Expected output:** an error
starting with `DRY RUN (rolled back):` followed by the weekly rows as JSON.

```sql
do $$
declare v_mech uuid; v_rows jsonb;
begin
  select id into v_mech from public.workflows where name = 'Joe''s Auto Repair';
  update public.workflows set report_config = '{
    "period": "week", "show_count": true,
    "fields": [
      {"key": "invoice_amount",  "label": "Invoiced",  "unit": "$", "unit_position": "prefix", "agg": "sum"},
      {"key": "estimate_amount", "label": "Estimated", "unit": "$", "unit_position": "prefix", "agg": "sum"}
    ]}'::jsonb
  where id = v_mech;
  select jsonb_agg(r order by r.period_start) into v_rows
  from public.report_series(v_mech, '2026-10-01', current_date, 'America/Chicago') r;
  raise exception 'DRY RUN (rolled back): %', v_rows;
end;
$$;
```

- **Expect** each `period_start` to be a Monday. `item_count` should match the jobs created that
  week, and the week of the job holding 300/500 shows `invoice_amount` 500 and `estimate_amount`
  300.
- **Why keep it.** This is the only check in the plan that runs the RPC's `week` branch,
  `item_count > 1` aggregation across items, and a config edited without code. Nutrition's own
  report is day-period with one item per day. It costs one file, it's zero-risk because it rolls
  itself back, and it isn't a commitment: committing a mechanic config, and choosing
  creation-week vs. invoiced-week bucketing, remain the user's calls.

### Step 8. Build, deploy, UI check

```bash
cd /home/mmcbride/micah/claude/workflow-app/web && dotnet build
```

Then push to `main`. That needs the user's go-ahead, since it triggers `deploy-pages.yml`. Confirm
the Pages deploy succeeded. Then, on the phone:

1. **Nutrition list.** A "Report" link appears. The mechanic and Feature Pipeline lists have none.
2. **Report page, 7-day chip.** 6 field cards. Today's values match today's item. 11-12 and 11-13
   are separate days in the period list. Switch to 30 and confirm the trend has 30 slots, with
   the last one faded.
3. **Goals.**
   - Protein goal 150 from today: progress bar plus "N g to go". The goal line appears only from
     today.
   - Then 140 from yesterday: yesterday uses 140, today still uses 150.
   - A sugar goal of 0: the bar is empty with "Met" on a day with no sugar, and red, full, "Ng over"
     on a day with some.
4. **Real forward-move path, including a correction.** On today's item:
   - Breakfast values → Complete Stage to Brunch → Brunch values. Report = breakfast + brunch.
   - Move back to Breakfast, correct a value, and move forward to Brunch again. **Report =
     corrected breakfast + brunch, not original + corrected + brunch.** (Brunch must be re-entered,
     because the forward move cleared it. That's pre-existing behaviour, D1.)
5. **Weight.** Set `weight_lbs` via chat on two days. The card shows the latest reading as a line.
6. **List label.** The 11-12 evening item reads `… 2026-11-12`.

### Step 9. Commit and PROGRESS.md

**Only after Step 4's checks print `PASS`, Step 7 prints its dry-run rows as expected, and every
Step 8 phone check passes.** If any of them fails, fix it and re-run before committing.

- Commit everything in one commit: the three migrations, `scripts/report_series_dev_check.sql`,
  `scripts/report_mechanic_dry_run.sql`, the client, the pages and the JS. The message should
  explain snapshot-on-clear and the per-stage dedupe.
- Note: Step 8's deploy push already put the web code on `main`. If the user wants everything in a
  single commit, do Step 8's checks against a local `dotnet run` first and push once here. That's
  the user's call at Step 8.
- In PROGRESS.md, add the Report under "Dev pulled ahead of prod" and add it to the not-yet-ported
  list. Also note the deferred write-side follow-up (backward moves restoring per-stage values,
  D1).

## 4. Assumptions not verified

Each entry gives the assumption, how a failure would show up, and the concrete fallback.

- **`set local role authenticated` and `set_config('request.jwt.claims', …)` work inside a `DO`
  block run through `supabase db query --linked`.**
  - Detection: the block errors with a permission/role error instead of `PASS`/`FAIL`.
  - Fallback: paste the same file into the dashboard SQL editor. If that's also refused, Step 8
    check 4 covers the same path on real data.
- **PostgREST picks up the new RPC and table right after `db push`**, through Supabase's DDL
  event trigger.
  - Detection: the report page gets a 404/PGRST202 on `rpc/report_series`.
  - Fallback: `supabase db query --linked "notify pgrst, 'reload schema'"`.
- **`Intl…timeZone` returns an IANA name Postgres recognises.**
  - Detection: the RPC errors with `time zone "…" not recognized`.
  - Fallback: the client retries once with `'UTC'` and shows a small "times shown in UTC" note.
- **`<input type=date>` binds to `DateOnly` with `@bind` in .NET 10 Blazor.**
  - Detection: a compile error, or the value not round-tripping in Step 8 check 3.
  - Fallback: bind to a `string` field and parse it with
    `DateOnly.ParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture)` on Save.
- **The user agrees carbs and fat default to `at_most`.**
  - Detection: the user says otherwise.
  - Fallback: a new one-line content migration
    `update public.workflows set report_config = jsonb_set(report_config, '{fields,1,goal_direction}', '"at_least"') where name = 'Nutrition Tracker';`
    (index 2 for fat), with no code change. Existing goal rows keep their numbers; only met/missed
    flips.
- **`--colorPaletteGreenForeground1` and `--colorNeutralBackground3` exist under Fluent UI Blazor
  v5.**
  - Detection: the bar renders in the hex fallback colour instead.
  - Fallback: none needed. The fallbacks are deliberate final values.

## 5. Risks and edge cases

- **Redefining `move_stage` (fourth time).**
  - Mitigated by the Step 4 diff plus `DO`-block checks 5 and 6.
  - Rollback: re-run `20261113000000`'s body as a new migration. Old events keep their `cleared`
    data, which is harmless.
- **Backward navigation without editing (D1 residual).** If a user backs out of a stage and moves
  forward again without editing, the earlier stage's original values get replaced by the carried-over
  ones. The report then matches the stage UI, which loses the same data the same way. This is
  pre-existing `move_stage` behaviour. The write-side fix is named in D1 and deferred.
- **Logging on past days.** Values count toward the item's creation day, by design. The report makes
  "logged today's breakfast onto yesterday's item" *visible*; it doesn't guess.
- **Sum with partial data.** Missing fields show "—", not 0.
- **Shared keys meaning different things across stages.** That's not the case today. Supporting it
  would be a config extension.
- **Mechanic revenue by creation week (D5).** A known gap.
- **Goal rows are append-only.** A typo is superseded, not deleted.
- **Prod.** These three migrations go to prod with the 2026-11-12 batch. With `report_config` null
  there, the feature is inert.
- **Rollback.**
  - Web: revert the commit.
  - DB: the column and table are additive. Roll back `move_stage` as above.

## 6. Out of scope (deliberate)

- Cross-workflow reports, custom queries, export, saved views, per-user configs.
- Derived fields (calories = 4p + 4c + 9f; profit).
- Turnaround metrics and `date_anchor: "terminal"`.
- Committing a mechanic `report_config`.
- Agent/chat access to report numbers or goals.
- Backfilling the pre-snapshot test day.
- Back-dating items.
- Porting to prod.
- **The write-side `move_stage` change that would make backward navigation snapshot and restore
  per-stage values** (D1 residual). It's a named follow-up for the architect and user to accept or
  reject. It isn't built here.

## Feedback from this round

**Sanity-check, blocking**

1. **Double-counting on re-crossed boundaries: adopted, with one deliberate change.**
   - The fix is entirely read-side, in `report_series`. A new `raw_segments` → `segments` step keeps
     only the latest `seq` per (item, stage, field) before `agg` runs. `move_stage`'s write side is
     unchanged apart from a comment telling readers to dedupe.
   - **Change: keyed on `from_stage_id`, not the suggested `to_stage_id`.** The sanity-check's own
     stated intent was "the last time the item left this particular stage", and that stage is
     `from_stage_id`. Nutrition allows forward skips, so `to_stage_id` keying still double-counts
     when two departures from the same stage land on different stages. Check 4 in the Step 4 `DO`
     block distinguishes the two (60 vs 75).
   - **Extension:** the live value is keyed to the item's current stage and supersedes that stage's
     older snapshot. Without this, correcting the stage you backed into re-creates the same double
     count.
   - **Honest trade-off, surfaced rather than buried.** Dedupe fixes the correction case but changes
     the "back out without editing, then forward" case: round 1 happened to total that correctly,
     and now the carried-over values replace the earlier stage's snapshot. I judged dedupe correct
     anyway, because it makes the report match what the stage UI shows, and the alternative
     double-counts every correction. The real fix is write-side and is named and deferred in D1.
     The architect should weigh whether to pull it in.
   - Added the backward-correct-forward and forward-skip cases to Step 4 (asserted) and Step 8 (on
     the phone), as suggested.
2. **CHECK constraint passes on NULL: adopted.**
   - It now requires `jsonb_typeof = 'object'` and `?& array['period','fields']`, and uses
     `coalesce` on both value tests, so no conjunct can be NULL for a non-null config.
   - Four negative probes were added to the Step 4 block.
   - I applied the same NULL lesson to the new `report_goals.target >= 0` CHECK, which is NULL-safe
     on purpose, and to the test assertions themselves, which use `is distinct from` rather than
     `<>` so that a null result fails.

**Sanity-check, non-blocking**

3. **Same bar metaphor for `at_least` and `at_most`: adopted (lightweight).** The fill colour and
   text now differ by direction: green "Met" vs red "over"; "to go" vs "left". The goal is written
   with ≥/≤. I didn't build a separate depleting-bar widget, because colour plus text already
   removes the at-a-glance ambiguity.
4. **0/0 → NaN: adopted.** `Fraction()` defines every case. The `report_goals` CHECK guarantees
   `target >= 0`, and the form enforces `min=0`. The same kind of guard was added for the trend
   chart's scale (max = 0).
5. **Use `ISOWeek`: adopted for week truncation (`PeriodStart`).** Stepping stays `AddDays(7)` from
   a Monday. I disagree with part of the rationale: `DateOnly` arithmetic has no DST, and a
   Monday-anchored +7 doesn't drift at year boundaries. But `ISOWeek` costs nothing and makes the
   match with `date_trunc('week')` explicit rather than argued.
6. **Cut Step 7 dry run: rejected (kept).** It's the only check of the RPC's `week` branch and of
   multi-item period aggregation, since Nutrition is day-period with one item per day. It's now a
   self-rolling-back `DO` block, so it's zero-risk.

**Plan-reviewer**

1. **`<id>` placeholder across statements: adopted.** Section 0.2 documents how SQL actually runs
   here: no psql, so no `\gset`; `supabase db query --linked -f`. Every write check is now a single
   `DO` block with plpgsql variables that always ends in a raise, so it rolls back atomically
   regardless of how the Management API handles transactions.
2. **Owner `user_id` placeholder: adopted.** The block now contains the actual
   `account_members ⨝ workflows where role = 'owner' order by created_at limit 1` query.
3. **Chip `from` arithmetic: adopted.** N = N periods including the current partial one:
   `from = PeriodStart(today) − (N−1) periods`, with worked examples. The range summary excludes the
   partial period (stated, with the reason). The partial bar is faded.
4. **Month stepping: adopted.** Anchor on the 1st, then `AddMonths(1)`. That never clamps and equals
   `date_trunc('month')`. Written as code next to the week rule.
5. **Colours and `ButtonAppearance`: adopted.** Section 0.4 lists the real tokens: `--app-accent`,
   and `var(--colorPaletteRedForeground1, #c00)` from `WorkflowDetail`. Green and neutral follow the
   same token-plus-fallback convention. `Appearance.Primary` is corrected to
   `ButtonAppearance.Primary`.
6. **Step 9 gating: adopted.** It now states it's gated on Steps 4, 7 and 8 passing. It also flags
   that Step 8's deploy push already lands the web code, so a single commit needs local testing
   first. That's the user's call.
7. **Uneven fallback detail in Section 4: adopted.** Every entry now has the same three parts:
   assumption, how the failure shows up, and the concrete fallback (including the exact
   `jsonb_set` content migration and the `DateOnly.ParseExact` string binding).

**Also corrected in passing (not raised by either reviewer)**
- Round 1 implied `phase3_sdlc_order_test.py` might run against dev. It can't, because it's
  hard-coded to the local stack. Feature Pipeline coverage is now the Step 4 diff plus `DO`-block
  check 6 when an enforce-ordered workflow is visible.
- Round 1's transaction test expected an absolute protein of 50 for today. That would have failed
  against the real 11-15 item's 52 g. The checks now measure deltas against a baseline.
