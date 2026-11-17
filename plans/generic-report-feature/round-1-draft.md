# Generic per-workflow Report: round-1 draft

Dev only: repo `/home/mmcbride/micah/claude/workflow-app`, Supabase project `workflow-engine-test`
(ref `utwyvtbzesswpoihmlic`, linked). Nothing here touches `workflow-app-prod`.

## 0. Ground truth (checked read-only against dev, 2026-11-15)

Read: CLAUDE.md, PROGRESS.md, every migration, `WorkflowDetail.razor`, `WorkflowApiClient.cs`,
`agent-loop/index.ts`, `plans/diet-workflow/final-plan.md`. Plus read-only
`supabase db query --linked` selects against dev.

### 0.1 The task brief describes the Nutrition Tracker data model wrongly, and it matters

The brief says each meal is a separate item, with macros as flat totals in `item.data`. **That's the
superseded design, not what got built.** What's actually built (see
`20261112000000_add_nutrition_tracker_workflow.sql` and `20261113000000_move_stage_clears_shared_fields.sql`):

- **One item per day** (`item_label = 'meal date'`). It moves forward through
  breakfast → brunch → lunch → linner → dinner. That's 5 sequential stages, all sharing the same
  checklist keys (`protein_g, carbs_g, fat_g, fiber_g, sugar_g, weight_lbs`).
- **`move_stage` clears those shared keys from `item.data` on every forward move**
  (`20261113000000`). So at any moment, `item.data` holds **only the current stage's** values.
  Breakfast's numbers are gone from `item.data` as soon as the item reaches Brunch. They survive
  only as the last `item.data_changed` patch logged in `item_events` before the move.
- Values are **running totals per stage**, not deltas. Scan Plate writes `existing + scanned`
  (`ExistingPlus` in `OnFoodPhotoSelected`). Chat corrections write absolute values.

Consequence: **a daily total can't be computed by summing `item.data` across a day's items.** For
any day that got past Breakfast, that would drop every earlier meal. Getting this right is the
hardest part of the feature, and Section 2 (D1) handles it.

Live dev data (4 Nutrition items, one per day):

| item | created_at (UTC) | stage now | moves |
|---|---|---|---|
| `a831e45f` | 2026-11-13 03:53 | dinner | 4 forward moves (seq 41, 42, 44, 54) |
| `b173bc11` | 2026-11-13 12:45 | breakfast | none |
| `fdd1665e` | 2026-11-14 13:20 | breakfast | none |
| `8c4775d6` | 2026-11-15 14:30 | breakfast | none |

- Every macro value is a JSON **number**. Some items also carry non-numeric keys (`description`,
  `eaten`).
- Item `a831e45f` was created at 03:53 UTC, which is **21:53 on 11-12 in America/Chicago**.
  Bucketed by UTC date it would land on the same day as `b173bc11`. That's concrete proof that
  bucketing by day must use a timezone (D5).
- Mechanic: the one job that has `estimate_amount` and `invoice_amount` stores both as JSON
  numbers (300, 500).
- Mechanic checklists (dev DB only, not in migrations): estimated = `estimate_amount`,
  `estimated_completion`; invoicing includes `invoice_amount`. No two mechanic stages share a key,
  so `move_stage`'s clearing never fires there, and `item.data` is the item's full record.

### 0.2 Special-casing precedent in `WorkflowDetail.razor` (documented honestly)

The page is generic, but it isn't free of special cases. There are two kinds.

- **`item_label == "job"` branches:**
  - the stage-detail header suffix (line 58);
  - list and search cards `#N title` (lines 283, 304);
  - `ItemDisplayName` (line 629);
  - `StartNewJob`'s chat-first creation (line 734).
- **Field-name capability gates**, a second kind of special-casing the brief didn't mention:
  - `Checklist.Contains("vin")` → Scan VIN;
  - `Checklist.Contains("protein_g")` → Scan Plate, which also hard-codes the five macro keys in
    `OnFoodPhotoSelected`;
  - `Checklist.Contains("scheduled_at")` → Other Appointments;
  - `FieldUnitSuffixes` hard-codes `_g` and `_lbs`.

So the tolerated level is "branch on a generic property or a well-known field name, never on a
workflow's name or id". **This plan adds no new branch of either kind.** The Report is gated only on
the presence of the new `workflows.report_config`.

### 0.3 Why the old "Nutrition Goal" stage was dropped, and why it doesn't bite here

- The superseded design (`plans/diet-workflow/final-plan.md`) had a `nutrition_goal` stage. A goal
  was an *item* in the meal workflow, with `*_goal_g` checklist fields, in an all-terminal-peer-stages
  shape.
- The sequential design that got built has exactly one `is_initial` stage (breakfast). A goal stage
  would have to be reachable as a creation target, so goals can't be items in that workflow.
- The shipped migration also notes "goals aren't a daily-recurring thing anyway".

Both objections are about **modelling goals as items/stages**. This plan's goals (D4) are not items.
They're rows in a small side table outside the items/stages/is_initial machinery. So neither
objection applies.

## 1. What gets built (shape)

1. **Snapshot on clear.** `move_stage` records the values it clears inside its own
   `item.stage_changed` event (`data = {"cleared": {...}}`). This makes per-stage totals recoverable
   with simple SQL.
2. **Config.** A new `workflows.report_config jsonb` (nullable) says which `data.*` keys to report,
   how each one aggregates, its unit and label, its goal direction, and the period (day/week/month).
   `null` means no report.
3. **Read path.** One `report_series` RPC (security invoker) returns per-period aggregated values
   for a date range in a caller-supplied timezone.
4. **Goals.** A new append-only `report_goals` table holds dated targets per (workflow, field).
5. **UI.** A new generic page `/workflow/{WorkflowId}/report` (`WorkflowReport.razor`) with
   current-period cards, goal progress, a per-field trend chart over the range, and a way to set a
   goal. It's linked from `WorkflowDetail`'s list view only when `report_config` is set.
6. **Content.** Nutrition Tracker gets a `report_config`. The mechanic does **not** get one in this
   plan, but Step 7 dry-runs one in a rolled-back transaction to prove it works with no code.

## 2. Decisions

### D1. Per-stage values are captured at write time, in `move_stage`'s own event (judgment call)

**Chosen.** In `move_stage`, before `data - v_shared_keys` runs, build
`jsonb_object_agg(k, data->k)` over the shared keys actually present, and store it as
`{"cleared": <obj>}` in the `item.stage_changed` event's `data`. Today that `data` is always null.
It stays null when nothing was cleared, so the mechanic and Feature Pipeline are byte-identical.

**How an item's value for field `k` is computed:**
- Take its *segments*: the live `data->k` (if present), plus `cleared->k` from each of its
  `stage_changed` events.
- Combine them with the field's `agg`.

Invariant: every value that ever sat in `item.data[k]` at a forward move is counted exactly once.
Either it was cleared (and snapshotted), or it's still live. Values overwritten before a move were
corrections and are correctly not counted. Here's a walkthrough of backward-then-forward
(lunch → breakfast → brunch):

1. Lunch's values stay in `data` across the backward move, because backward moves don't clear.
2. They're snapshotted on the next forward move.
3. They're no longer live after that, so they're still counted once.

**Rejected: deriving pre-clear values on read.** That would replay `item_events`:
- for each forward move, find the last write of each shared key since the previous clear;
- use the *current* stages' checklists to decide which keys a historical move cleared.

It's doable in one lateral query, but:
- it's a materially more complex read query, permanently;
- it silently re-interprets history whenever a checklist is later edited;
- it can't tell moves made before `20261113000000` existed (which cleared nothing) from moves made
  after.

Write-time capture records what actually happened.

**Rejected: per-stage namespaced keys** (`breakfast_protein_g`). It would undo the shared-checklist
design that scan-plate, the agent prompt, and the checklist UI all rely on.

**Rejected: a separate snapshot table.** `item_events` already exists for exactly this: "what
happened to this item, tagged by stage". The `data` column on `stage_changed` events is unused.

### D2. No backfill of historical events (judgment call)

Checked live (Section 0.1): only **one** Nutrition item has ever moved forward, `a831e45f`. Its first
three moves (03:54–04:03 UTC on 11-13) came minutes after commit `49d663a`
(`20261113000000`, committed 03:48 UTC). There's no record of when that migration was actually
pushed, so whether those moves cleared anything is unknowable.

The other three days never left Breakfast, so their totals are fully correct with no backfill. A
backfill would mean:
- an `UPDATE` on the append-only audit log;
- guessing the semantics of exactly one test-like day.

So: **no backfill.** That day (local 2026-11-12) reports dinner's live values only. This is stated in
the migration comment. If the user cares, a one-off hand correction of that day is a 3-line SQL
update, explicitly not part of this plan.

### D3. Config is one `workflows.report_config jsonb` column

Shape (validated loosely by a check constraint, strictly by the RPC and client):

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
| `period` | `day`, `week`, `month` | (required) | Weeks are ISO (Monday start, Postgres `date_trunc('week')`). |
| `show_count` | boolean | `false` | Shows items per period. That's throughput for the mechanic, noise for nutrition (always 1/day). |
| `fields[].key` | any `data.*` key | (required) | |
| `fields[].agg` | `sum`, `avg`, `last` | `sum` | Applied at both levels: segments within an item, then items within a period. `last` exists because `weight_lbs` is a reading, not an amount. Summing weights across meals would be nonsense. |
| `fields[].label` | text | the key, humanized | Same as `ChecklistLabel`. |
| `fields[].unit` | text | none | No fallback to the `_g`/`_lbs` suffix convention, because config is migration-authored. Being explicit is free, and it avoids extracting `FieldLabelAndUnit` out of `WorkflowDetail`. |
| `fields[].unit_position` | `prefix`, `suffix` | `suffix` | Exists only so the mechanic's `$` can read `$500`. |
| `fields[].goal_direction` | `at_least`, `at_most` | `at_least` | Decides whether a goal is met. Protein is at-least, sugar is at-most. This is a property of the field, not of a particular target value, so it lives in config, not on goal rows. |

**Why a jsonb column on `workflows`, not new tables or stage columns.**

- **Precedent.** `checklist` (`20261104020000`) explicitly chose "a plain jsonb array of strings, not
  a child table -- these are just hints read for context, not entities with their own
  identity/ordering/relationships worth a join everywhere stages are already fetched." Report field
  definitions are the same kind of thing. They're static, migration-authored display/semantics
  metadata, read wholesale by one page, with no identity of their own.
- **Workflow level, not stage level.** A report spans stages: a day's protein is breakfast + ... +
  dinner, and mechanic revenue is set in invoicing but reported per job. Per-workflow display
  settings already live on `workflows` (`item_label`, `enforce_stage_order`).
- **One nullable column** also gives the on/off switch for free.

**Rejected: a `report_fields` child table** (workflow_id, key, agg, unit, ...). It's more DDL, RLS
and grants for rows nobody ever edits from the app. It's only worth it once fields need identity,
for example per-user field selection, and nothing asks for that.

**Rejected: putting report hints on `stages.checklist` entries.** That would turn strings into objects
and break every reader of `checklist`. `20261111000000` explicitly avoided exactly this when it added
`optional_checklist` as its own column.

### D4. Goals are dated, append-only rows in a new `report_goals` table (judgment call)

**Chosen.** `report_goals(workflow_id, field_key, target numeric null, effective_from date,
created_by, created_at)`.
- A goal applies from `effective_from` until a later row for the same field supersedes it.
- `target = null` means "no goal from this date".
- No UPDATE or DELETE (same append-only stance as `item_events` and `agent_events`). A correction
  is a new row. For the same `effective_from`, the latest `created_at` wins.

**Why dated, not one static number.**

1. **History.** A static goal retroactively rewrites every past period's met/missed status the
   moment it changes. "Did I hit protein on Nov 3?" must not change because I raised the target on
   Dec 1. The trend chart's goal line is exactly where that would show.
2. **Who changes it, and how.** Goals are user data that change on the user's schedule (cutting,
   bulking, a slow month at the shop). They need an in-app edit path. Config is migration-authored:
   changing a static goal in `report_config` would mean a migration, or a client read-modify-write of
   the whole config jsonb, which `workflows_update` RLS technically allows today. That mixes
   user-edited state into static metadata and risks lost updates.
3. **Cost is small.** One table, two policies, two grants, plus a tiny client-side "goal in effect on
   date X" lookup over a list that will never exceed tens of rows.

**Rejected: a static `goal` per field in `report_config`.** It fails points 1 and 2.

**Rejected: goals as items in a separate tiny "Goals" workflow** (the shipped migration's own
"possibly as its own tiny workflow later" idea).
- The report would have to reference another workflow by id or name. That's cross-workflow
  coupling the engine has nowhere else.
- The effective date would be the item's `created_at`, so no back-dating.
- "Supersede" semantics would have to be inferred from item ordering.

It reuses the engine in name only.

**Rejected: goals as a stage in the Nutrition workflow.** Section 0.3 covers why.

**Goal-in-effect rule.** A period's goal is the one in effect on the period's **last day**, or
**today** if the period is still in progress. For `day` this doesn't matter. For week and month, it
means a goal set mid-week applies to the current week immediately, which matches what a user
expects right after setting it.
- Alternative: in effect on the period's first day.
- Flagged for reviewers.

**Goal semantics are per period**: a protein goal of 150 on a `day` report means 150 per day. If a
workflow's `period` changes later, existing goal rows keep their number but change meaning. That's
acceptable because `period` is migration-authored and won't change casually. It's noted in the
migration comment.

### D5. Grouping: an item belongs to the period containing its `created_at`, in the viewer's timezone

- There's no container item anywhere. **The item is the unit**, and the period is
  `date_trunc(period, created_at AT TIME ZONE p_tz)`.
- For Nutrition, the item *is* the day.
- For the mechanic, a job counts toward the week it was created. If two Nutrition items land on the
  same day (a double "+ New"), `sum` adds them, which is correct.
- The timezone is passed by the client, from `Intl.DateTimeFormat().resolvedOptions().timeZone`
  via a 3-line JS helper. It falls back to `'UTC'` if the call fails.
- This matches the old diet plan's D4 ("grouping uses the browser's local date... the future
  reporting tool must use the same timezone convention").

**Rejected: a per-workflow `timezone` in config.** It's deterministic, but wrong for anyone viewing
from elsewhere. A single-user nutrition log is always viewed from the user's own zone.

**Rejected: `TimeZoneInfo.Local.Id`.** It probably yields an IANA id on .NET 10 WASM, but JS
interop removes the doubt for 3 lines.

**Known limitation, deliberately deferred.** For the mechanic, revenue is more naturally bucketed by
**when the job was invoiced or closed**, not when it was created. A future
`"date_anchor": "created" | "terminal"` config key would bucket by the first `stage_changed` into an
`is_terminal` stage. It's not built now, because nothing uses it yet (the repo's own "discover,
don't pre-assert" rule from phase0).

**Consistency fix included (Step 6).** `ItemDisplayName` renders `item.CreatedAt:yyyy-MM-dd`, which
uses the UTC offset PostgREST returns. So item `a831e45f` is labelled "… 2026-11-13" in the list,
while the report (correctly) calls it 11-12. Changing it to `item.CreatedAt.ToLocalTime()` makes
the list and the report agree. It's one expression, and Notes timestamps already use
`ToLocalTime()`.

### D6. Aggregation runs server-side in one RPC, not in the client

- `report_series(p_workflow_id, p_from, p_to, p_tz)` returns one row per non-empty period:
  `(period_start date, item_count bigint, field_values jsonb)`.
- It's security invoker, so RLS on `workflows`, `items` and `item_events` scopes it, exactly like
  `search_items`.
- This follows `search_items`' own stated reason ("runs server-side via the search_items RPC
  instead of loading every item client-side").

**Rejected: client-side.** It would need every item plus every item's events. That's N+1 requests,
or a PostgREST embed, and it grows with history.

**Coercion.** The RPC turns values into numbers via a small immutable helper
`private.jsonb_numeric`:
- JSON numbers pass through;
- strings like `"$1,250.00"` are parsed;
- anything else becomes null and is ignored.

All live data is numeric today (Section 0.1). The string tolerance is cheap insurance against the
agent writing `"$500"` someday.

### D7. UI: one generic page; inline SVG, no chart library (judgment call)

- **The page.** `web/Pages/WorkflowReport.razor`, `@page "/workflow/{WorkflowId}/report"`. It's the
  same parameterized-by-workflow-id pattern as `WorkflowDetail`. Layout is in Step 5.
- **Rejected: a chart package.** It means a new WASM payload dependency for a handful of bars. Fluent
  UI Blazor ships no chart.
- **Inline SVG instead.** About 40 lines of Razor: bars per period, plus a goal step-line.
- **Component choice.** Fluent UI Blazor is **v5.0.1** here, and v5 renamed or reshaped many v4
  components. So the page uses only components `WorkflowDetail` already uses successfully
  (`FluentCard`, `FluentStack`, `FluentButton`, `FluentLink`, `FluentSpinner`, `FluentMessageBar`),
  plus plain HTML `<input>` (as the Scan Plate portion input already does) and a plain-div progress
  bar. That avoids guessing at v5 APIs like `FluentProgress`/`FluentProgressBar`.

### D8. The agent loop is untouched

The report never goes through chat. "How much protein today?" via chat is a natural follow-up: a
read tool calling `report_series`. It's out of scope here.

## 3. Steps

### Step 1. Migration: `move_stage` snapshots what it clears

File: `supabase/migrations/20261115000000_move_stage_records_cleared_values.sql`

**Copy the full current body from `20261113000000_move_stage_clears_shared_fields.sql` and change
only the marked lines.** `20261016130000` once silently dropped the enforce-stage-order check by
rewriting this function without it. Step 3 diffs the new body against the old one before pushing.

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

Notes:
- `v_item` still holds the pre-update row at that point, because it's `select ... for update`'d at
  the top and reassigned only by the UPDATE's `returning`.
- `jsonb_object_agg` over zero rows returns null, so no special case is needed.
- **Consumers of `stage_changed.data`.** `GetItemEventsAsync` exists, but no Razor code calls it.
  `scripts/phase1_happy_path_test.py` and `phase1b` check event counts and from/to pairs, not
  `data`. Nothing reads it today.

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

alter table public.workflows
  add column report_config jsonb
  constraint workflows_report_config_shape check (
    report_config is null or (
      report_config->>'period' in ('day', 'week', 'month')
      and jsonb_typeof(report_config->'fields') = 'array'
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
-- 21:53 Central entry is not tomorrow's). An item's value for a field combines its "segments":
-- its live data value plus every value move_stage cleared off it (20261115000000), so a
-- Nutrition day sums all its meals while a mechanic job (no shared keys, nothing ever cleared)
-- is just its live data. security invoker: RLS on workflows/items/item_events scopes rows, same
-- as search_items.
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
  ),
  its as (
    select i.id, i.data, i.created_at,
      case cfg.c->>'period'
        when 'day'   then (i.created_at at time zone p_tz)::date
        when 'week'  then date_trunc('week',  i.created_at at time zone p_tz)::date
        when 'month' then date_trunc('month', i.created_at at time zone p_tz)::date
      end as period_start
    from public.items i, cfg
    where i.workflow_id = p_workflow_id
      and (i.created_at at time zone p_tz)::date between p_from and p_to
  ),
  segments as (
    -- live value ranks after every cleared snapshot (max bigint as its "seq")
    select its.id as item_id, f.key, f.agg,
           private.jsonb_numeric(its.data -> f.key) as v, 9223372036854775807::bigint as seq
    from its cross join fields f
    where its.data ? f.key
    union all
    select e.item_id, f.key, f.agg,
           private.jsonb_numeric(e.data -> 'cleared' -> f.key), e.seq
    from public.item_events e
    join its on its.id = e.item_id
    cross join fields f
    where e.event_type = 'item.stage_changed' and e.data -> 'cleared' ? f.key
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

**Things to double-check while implementing:**
- An unknown `agg` makes the `case` yield null, so the field just shows "—". The client also
  ignores unknown aggs. There's no hard error. That's a judgment call; a `raise` would need plpgsql.
- **Index coverage.** `items(workflow_id)` exists, and so does `item_events(item_id, seq)`. Both are
  fine at the volumes involved (about 1 item/day for nutrition, a few jobs/day for the mechanic).
- Carbs and fat as `at_most` is a reasonable default, not something the user stated. Confirm with
  the user. It's content only, a one-line change.

### Step 3. Migration: `report_goals`

File: `supabase/migrations/20261115020000_add_report_goals.sql`

```sql
-- Dated report goals (2026-11-15). A goal is user data that changes on the user's schedule
-- (cutting/bulking, a slow month), and a past period's met/missed must not be rewritten when it
-- does -- so goals are dated rows that apply from effective_from until superseded, not one static
-- number in workflows.report_config. Deliberately NOT items/stages: the superseded diet design's
-- "nutrition_goal" stage couldn't coexist with the shipped sequential workflow's single
-- is_initial stage, and goals aren't daily-recurring entries anyway (20261112000000). target null =
-- "no goal from this date". Append-only like item_events/agent_events: a correction is a new row
-- (latest created_at wins for the same effective_from). field_key is not FK-checked against
-- report_config -- it's jsonb -- the UI only offers configured fields.

create table public.report_goals (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null references public.workflows (id),
  field_key text not null,
  target numeric,
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

### Step 4. Push and verify the database side

```bash
cd /home/mmcbride/micah/claude/workflow-app
diff <(sed -n '/create or replace function/,$p' supabase/migrations/20261113000000_move_stage_clears_shared_fields.sql) \
     <(sed -n '/create or replace function/,$p' supabase/migrations/20261115000000_move_stage_records_cleared_values.sql)
# expect ONLY: the v_cleared declaration, the jsonb_object_agg block, and the insert's data column
supabase db push --linked --dry-run   # expect exactly the three new files
supabase db push --linked
```

**Read-only checks.**

```sql
select * from public.report_series(
  (select id from workflows where name = 'Nutrition Tracker'),
  '2026-11-10', '2026-11-16', 'America/Chicago');
```

Expect exactly 4 rows: 11-12, 11-13, 11-14, 11-15. Each has `item_count` 1, and `field_values`
equal to that item's live macros from Section 0.1:
- 11-12 → protein 38 (`a831e45f`'s dinner values; D2);
- 11-13 → protein 90;
- 11-14 → protein 45;
- 11-15 → protein 52.

Re-run with `'UTC'` and expect 3 rows, with 11-13's `item_count` = 2. That confirms the timezone
matters.

**Forward-move snapshot check.** This needs a write, so it runs in a rolled-back transaction as
the real user:

```sql
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<the Nutrition account owner user_id from account_members>","role":"authenticated"}';
select id from public.create_item((select id from workflows where name='Nutrition Tracker'), '{}') ;  -- note id
select public.update_data('<id>', '{"protein_g": 30, "weight_lbs": 180}');
select public.move_stage('<id>', (select id from stages where title='brunch' and workflow_id=(select id from workflows where name='Nutrition Tracker')));
select public.update_data('<id>', '{"protein_g": 20}');
select data from item_events where item_id = '<id>' and event_type = 'item.stage_changed';
--   expect {"cleared": {"protein_g": 30, "weight_lbs": 180}}
select * from public.report_series((select id from workflows where name='Nutrition Tracker'),
  current_date, current_date, 'America/Chicago');
--   expect protein_g 50, weight_lbs 180
rollback;
```

If `supabase db query` can't hold a multi-statement transaction with placeholders, run it in the
dashboard SQL editor instead. If neither works, the Step 8 UI check covers the same path for real.

**Mechanic regression (also in a rolled-back transaction).** Move one mechanic test job forward one
stage and confirm the new `stage_changed` row has `data` null. Also run `phase3_sdlc_order_test.py`
if it's runnable against dev, to prove the forward-skip check survived.

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

**Changed:** `WorkflowSummary` gets a trailing optional parameter,
`public record WorkflowSummary(string Id, string Name, string ItemLabel, ReportConfig? Report = null);`.
- `GetWorkflowAsync` adds `report_config` to its `select` and parses it with a private
  `ParseReportConfig(JsonNode?)`. That function returns null on a null node, and skips fields
  missing `key` or with an unknown `agg`.
- The label defaults to the humanized key.
- `GetWorkflowsAsync` is unchanged; its 3-argument construction still compiles.
- One fetch serves both `WorkflowDetail` (for the link) and the report page. No extra request.

**New methods:**
- **`GetReportSeriesAsync(string workflowId, DateOnly from, DateOnly to, string tz)`.** POSTs
  `/rest/v1/rpc/report_series`, same shape as `SearchItemsAsync`. Dates go out as `yyyy-MM-dd`.
  `field_values` becomes a dictionary of doubles.
- **`GetReportGoalsAsync(string workflowId)`.** A GET on
  `/rest/v1/report_goals?workflow_id=eq.{id}&select=field_key,target,effective_from,created_at&order=effective_from.asc,created_at.asc`.
- **`AddReportGoalAsync(string workflowId, string fieldKey, double? target, DateOnly effectiveFrom)`.**
  A POST to `/rest/v1/report_goals`, same pattern as `AddChatMessageAsync`. `created_by` is left to
  its `auth.uid()` default.

### Step 6. UI

**6a. `web/wwwroot/js/timezone.js` (new).**
`window.getTimeZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone;`. Plus a
`<script src="js/timezone.js"></script>` next to `focus.js` in `index.html`.

**6b. `WorkflowDetail.razor`, two small edits:**
- In the list view, after the Show/Hide closed link, add:
  `@if (_workflow?.Report is not null) { <FluentLink Href="@($"workflow/{WorkflowId}/report")" Class="back-link" Style="margin-left:16px;">Report</FluentLink> }`.
  The `Href` is relative, like `Home.razor`'s `NavigateTo($"workflow/{id}")`, so the GitHub Pages
  subpath and the existing `404.html` SPA redirect both apply unchanged.
- `ItemDisplayName`: change `{item.CreatedAt:yyyy-MM-dd}` to
  `{item.CreatedAt.ToLocalTime():yyyy-MM-dd}` (D5).

**6c. `web/Pages/WorkflowReport.razor` (new).**

`@page "/workflow/{WorkflowId}/report"`, injecting `WorkflowApiClient` and `IJSRuntime`.

Load sequence:
1. `GetWorkflowAsync`. If `Report` is null, show "This workflow has no report configured." and a
   back link.
2. `tz = await JS.InvokeAsync<string>("getTimeZone")`, falling back to `"UTC"` on exception.
3. Compute `today` in that zone as the browser's local date (`DateTime.Now` is the browser zone in
   WASM, the same assumption Notes timestamps already rely on).
4. Range from the selected chip:

   | period | chips | default |
   |---|---|---|
   | `day` | 7 / 30 / 90 days | 7 |
   | `week` | 8 / 26 / 52 weeks | 8 |
   | `month` | 6 / 12 / 24 months | 6 |

   `from` is the start of the earliest period. `to = today`.
5. `GetReportSeriesAsync` and `GetReportGoalsAsync`, in parallel (`Task.WhenAll`).
6. Build the full list of period starts from `from` to `today`, stepping by period with Monday-start
   weeks to match Postgres. Join it to the rows. **A missing period is "no data" (shown as —), not
   0.** A day not logged is not a zero-protein day.

Rendering, top to bottom (single column, phone-first; the user is on a phone):
- **Header.** Back link `← {ItemLabelPlural}` to `workflow/{WorkflowId}`, the `ThemeToggleButton`
  (same header layout as `WorkflowDetail`), and an `<h1>` of `{workflow.Name} report`.
- **Range chips.** Three `FluentButton`s, with the selected one `Appearance.Primary`.
- **One `FluentCard` per configured field:**
  - **Title line.** The label, then the current period's value formatted with its unit ("52g",
    "$500"), and the current period's name ("Today" / "This week" / "This month").
  - **If a goal is in effect for the current period:** "of 150g", plus a plain-div progress bar
    (width = min(value/target, 1)).
    - Green when met (`value >= target` for at-least, `value <= target` for at-most).
    - Otherwise the accent color.
    - A status line: "98g to go" / "12g over" / "Met".
  - **Range summary.** Average over periods *with data*, and "Goal met on N of M days/weeks". M
    counts only periods that had both data and a goal.
  - **Trend.** Inline `<svg viewBox>` with width 100%, height about 80px.
    - One bar per period in the range (no bar for no-data periods).
    - Bars scaled to max(value, goal) over the range.
    - The goal drawn as a polyline step at each period's own goal, so goal changes are visible.
    - Each bar has a `<title>` tooltip with date and value.
    - For `agg == "last"` (weight), draw a polyline of points instead of bars. A reading trend reads
      better as a line. This is chosen by `agg`, a generic property, not by field name.
  - **"Set goal" link.** It expands an inline form: `<input type=number step=any>` for the target,
    `<input type=date>` defaulting to today, Save, and "Remove goal" (saves `target = null`). On
    save, call `AddReportGoalAsync` and reload goals only. Disable Save while saving and show errors
    inline, same as the scan error lines.
- **Period list.** Collapsed by default behind a "Show each day/week/month" link. It's newest first,
  one line per period: `Nov 15 — Protein 52g · Carbs 55.5g · …`. It appends
  `· {count} {ItemLabelPlural}` when `ShowCount` is set.
  - When `ShowCount` is set, the summary area also gets an "{ItemLabelPlural} this period" card
    (count, average count over the range), using the same card rendering with no goal. This is the
    mechanic's throughput.

**Goal resolution** is a client helper:
`GoalFor(fieldKey, DateOnly periodStart) → double?`. It uses `asOf = min(periodEnd, today)` and picks
the last goal for that field with `EffectiveFrom <= asOf`, ordered by `(EffectiveFrom, CreatedAt)`.
It returns that goal's `Target`, which may be null.

**Number formatting:** `0.#` for values, with no thousands grouping for `g`. The `$` prefix uses
`N0` if the value is whole and `N2` otherwise. These are invariant-culture strings, the same
convention as the rest of the file.

### Step 7. Prove genericity on the mechanic with no code (dry run, rolled back)

```sql
begin;
update public.workflows set report_config = '{
  "period": "week", "show_count": true,
  "fields": [
    {"key": "invoice_amount",  "label": "Invoiced",  "unit": "$", "unit_position": "prefix", "agg": "sum"},
    {"key": "estimate_amount", "label": "Estimated", "unit": "$", "unit_position": "prefix", "agg": "sum"}
  ]}'::jsonb
where name = 'Joe''s Auto Repair';
select * from public.report_series((select id from workflows where name = 'Joe''s Auto Repair'),
  '2026-10-01', current_date, 'America/Chicago');
rollback;
```

- **Expect** weekly rows whose `item_count` matches the jobs created that week. The job holding 300
  and 500 should show up in its creation week.
- **Not committed as content in this plan.** Whether the shop wants it, and created-week vs.
  invoiced-week bucketing (D5), are the user's calls, along with porting to prod.
- **Committing it later is a one-line content migration and zero code.** That's the acceptance test
  for "generic".

### Step 8. Build, deploy, UI check

```bash
cd /home/mmcbride/micah/claude/workflow-app/web && dotnet build
```

Then push to `main` (with the user's go-ahead; this triggers `deploy-pages.yml`) and confirm the
Pages deploy succeeded. On the phone:

1. **Nutrition list.** There's a "Report" link. The mechanic and Feature Pipeline lists have none.
2. **Report page, 7 days.** It shows 6 field cards. Today's values match today's item. 11-12 and
   11-13 are separate days in the period list.
3. **Goals.**
   - Set a protein goal of 150 effective today. The today card shows a progress bar and "N g to go".
     The trend's goal line appears only from today.
   - Set a new goal of 140 effective yesterday. Yesterday's period now uses 140 and today's still
     uses 150, because the later `effective_from` wins for today.
4. **Real forward-move path.**
   - On today's item, Scan Plate (or chat) on Breakfast, then Complete Stage to Brunch, then add
     Brunch values.
   - The report's today value equals breakfast + brunch.
   - The item's own Brunch stage view still shows only Brunch's numbers (unchanged behavior).
5. **Weight.** Set `weight_lbs` via chat on two different days. The Weight card shows the latest
   reading, not a sum, and draws a line.
6. **List label.** The list's item label for the 11-12 evening item now reads `… 2026-11-12`.

### Step 9. Commit and PROGRESS.md

- Commit the migrations, client, pages and JS together, with a message explaining the
  snapshot-on-clear reasoning.
- Add the Report under "Dev pulled ahead of prod" in PROGRESS.md, and add it to the not-yet-ported
  list.

## 4. Assumptions not verified

- **`supabase db query --linked` transactions.** It runs multi-statement transactions with
  `set local role`/`request.jwt.claims`. Step 4 names the fallbacks.
- **PostgREST schema cache.** Supabase's DDL event trigger reloads it after `db push`, so the new
  RPC and table are callable right away. If not: `notify pgrst, 'reload schema';`.
- **Browser time.** `Intl...timeZone` returns an IANA name Postgres recognizes (it uses the same
  tzdata names). An unrecognized one makes the RPC error. The client then retries once with `'UTC'`
  and shows a small "times shown in UTC" note.
- **Date input.** `<input type=date>` binds cleanly to `DateOnly` in .NET 10 Blazor. If not, bind
  to a string and parse.
- **Goal directions.** The user agrees carbs and fat are "at most" by default (content only).

## 5. Risks and edge cases

- **Redefining `move_stage` (fourth time).** That's the highest-risk step, given the 2026-10-16
  regression. Mitigated by the diff in Step 4 and the Feature Pipeline test.
  - Rollback: re-run `20261113000000`'s body as a new migration. Old events keep their `cleared`
    data, which is harmless, because nothing else reads it.
- **Logging on past days.** Logging into a past day's item, or "Complete Stage" pressed the next
  morning, attributes values to the item's creation day. That's correct by design (the item is
  the day).
  - The reverse case is real, though: forgetting "+ New" and logging today's breakfast onto
    yesterday's Dinner item puts it on yesterday.
  - That's a user-workflow issue the report makes *visible*. It isn't something the report should
    guess at.
- **Backward move then edit.** Backward moves don't clear. So landing on Breakfast from Lunch shows
  Lunch's numbers under Breakfast, and overwriting them "fixes breakfast" while losing lunch.
  - That's pre-existing `move_stage` behavior, not introduced here. The report stays internally
    consistent (D1's invariant).
- **Sum with partial data.** A day with only some fields logged sums what exists. Missing fields
  show "—" for that day, not 0. (`sum` over zero segments is null, and the RPC drops null keys.)
- **One cleared snapshot per forward move.** If a future workflow's stages share a key but mean
  different things (not the case today), summing across stages would be wrong. `agg` can't express
  "only this stage's value". That's a config-shape extension (`stages` filter per field) if it ever
  comes up.
- **Mechanic revenue by creation week (D5).** That's a known semantic gap, with a named follow-up.
- **Goal rows are append-only.** A typo'd goal can't be deleted, only superseded or nulled. Same
  stance as the rest of the audit tables. Service-role SQL cleans up if ever really needed.
- **Prod.** Prod lacks `20261113000000`'s siblings from the 2026-11-12 batch. When the dev features
  are ported, these three migrations go with them. With `report_config` null, prod shows no Report
  link, so they're inert there.
- **Rollback.**
  - Web: revert the commit. The old client ignores the new column and table.
  - DB: the column and table are additive. `move_stage` as above.

## 6. Out of scope (deliberate)

- Any analytics platform behaviour: cross-workflow reports, custom queries, export or CSV, saved
  views, per-user report configs.
- Derived and computed fields. Calories as 4p + 4c + 9f is the obvious first one for nutrition, and
  profit = invoice − parts for the mechanic. A linear `"formula": {"protein_g": 4, ...}` field type
  would be a small follow-up on top of this shape.
- Turnaround/duration metrics (time from created to terminal), and `date_anchor: "terminal"` (D5).
- Committing a mechanic `report_config` (Step 7 only dry-runs it).
- Agent/chat access to report numbers or goal setting (D8).
- Backfilling or hand-correcting the one pre-snapshot test day (D2).
- Back-dating items. The report inherits "an item's day is its local `created_at`".
- Porting to prod.
- Any change to how Nutrition meals are entered, moved, or cleared, beyond recording the clear.
