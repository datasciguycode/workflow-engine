# Generic per-workflow Report: final plan (Nutrition weekly report: four daily averages)

**Status: PLANNING ONLY. Do not implement.** This is the architect-adjudicated final plan
(verdict: **approved-with-changes**, Section 10). It is round-6-draft.md plus the architect's
changes, and it fully supersedes the round-4 architect-approved plan that used to live at this
path. That plan is preserved unchanged as `round-4-final-plan.md` for history; every reference to
it below uses that name. This file stands on its own.
- **Round 5** narrowed the scope at the user's request. The architecture is unchanged; what changed
  is what Nutrition Tracker's report shows, plus everything that existed only to support the
  dropped parts. Section 8 lists every cut.
- **Round 6** is a targeted fix to one aggregation rule. The user answered the one question round 5
  left open: a day missing any of protein/carbs/fat is left out of **all four** averages (one
  shared day-set), not just calories. The user also confirmed calories is purely derived and never
  stored. Section 9 lists exactly what changed.

The only written records of the user's answers are the round-5 and round-6 task briefs, and this
file.

**The page shows exactly four numbers for the focused week:**
1. average calories per day;
2. average protein (g) per day;
3. average carbs (g) per day;
4. average fat (g) per day.

There is no macro % split, no weight, fiber or sugar, no days-included count, no goals, no trend
charts, and no chat or Q&A interface.

**Nothing in this plan has been implemented.** No code, migration, `supabase db push`, commit or
push happens until all three of these are true:
1. the user has reviewed and agreed to this plan;
2. the user has given an explicit answer to every item in Section A (see "How to answer" there);
3. the user has been **asked again** right before implementation starts and said go. The user
   asked for that second confirmation even after approving the plan.

Dev only: repo `/home/mmcbride/micah/claude/workflow-app`, Supabase project `workflow-engine-test`
(ref `utwyvtbzesswpoihmlic`, linked). Nothing here touches `workflow-app-prod`.

**Numbering note.** Decision IDs (D1–D10), Step numbers (1–9), Section A items and Step 8's phone
checks keep their numbers from earlier rounds. Removed items stay as one-line tombstones: D4,
Step 3 and Step 8 check 4.5. A.4 and the A.4 interpretation check were not removed: they were
answered, and stay in Section A as short "resolved" explanations so the decision is readable
where it was asked.

---

## A. Decisions the user needs to make before implementation

**How to answer.** Reply to each item by number. Each item has a stated default. "Defaults are
fine for A.1–A.3" counts as an explicit answer. When asking for the implementation go-ahead, the
orchestrating agent must repeat the answer recorded for each item, so nothing is assumed. The
answers are recorded here ("**Answer:** …") before Step 4.0 runs, and go into `PROGRESS.md` at the
next milestone (Step 9).

1. **Does the current week's average include today's unfinished day?** Today's item usually holds
   only breakfast (or nothing) until evening. If it's included, it pulls all four of the current
   week's averages down until the day is finished. A breakfast-only day usually has all three
   macros (Scan Plate writes all three), so the A.4 rule below doesn't exclude it. (If today so far
   has only some macros, e.g. protein logged through chat, A.4 leaves it out of all four averages
   until the missing ones are logged.)
   - **Default: include it.** It's the simplest option.
   - Alternative: for the *current* week only, the page passes `p_to = yesterday` instead of
     `today`. That's a one-line client change (Step 6c) and needs no SQL change. Downside: on a
     Monday the current week shows as empty (all four "—").
   - Past weeks are unaffected either way.
   - *What changed in round 5:* the default was originally justified partly by "the Days included
     card makes the effect visible". That card is gone, so the page no longer shows that today is
     a partial day. The default is unchanged, but it's now a closer call than it was. The week
     stepper (Step 6c) still shows last week's finished numbers one tap away.
   - **Answer: exclude it.** The user declined the default. The current week's report uses
     `p_to = yesterday` (the stated alternative), not `today`. This is the one-line client change
     in Step 6c — implement that branch, not the default's `p_to = today` behavior. Past weeks are
     unaffected. On a Monday, the current week shows as empty (all four "—") until Tuesday.
2. **Accept the D1 residual for now?** If you go back to an earlier stage and then move forward
   again *without editing*, the values carried over from the later stage replace the earlier
   stage's original values. The stage UI already loses this data in the same way today. The full
   fix is a write-side `move_stage` change: backward moves would snapshot and restore values. That
   changes what users see when they go back a stage, so it is **deferred** to a separate
   follow-up.
   - **Default: accept it, and defer the fix.**
   - **Answer: accept it for this rollout, but fix it as an immediate follow-up right after this
     ships** — not bundled into this push, and not left indefinitely deferred either. The full fix
     (backward-move snapshot/restore in `move_stage`) has not been designed anywhere in this
     pipeline; it needs its own planning pass (recommend running it through plan-pipeline the same
     way this feature was) once this report feature is live. Record this as a concrete next task in
     `PROGRESS.md` at the Step 9 milestone, not just a vague "known limitation" note.
3. **Commit and push sequencing (Step 8).**
   - **Default:** one commit for all the work, pushed to `main` once Steps 4 and 7 pass. The phone
     checks then run against the deployed Pages site, and any fixes go in follow-up commits.
   - The alternative is to test locally before any push. That needs the phone to reach a local
     `dotnet run`, and the Google OAuth redirect to allow that origin. Neither is set up today.
   - **Answer: confirmed, use the default.**
4. **(Resolved, not open: partial-macro days.)** The user chose **option (a)**: a day counts
   only if it has all three of protein_g, carbs_g and fat_g. **The filter is uniform across all
   four reported numbers** (settled by the user in round 6): calories, protein, carbs and fat are
   all averaged over the *same* set of days, those with all three macros. A day missing any macro
   is left out of every average, not just calories. This applies D9's rule ("a field that was never
   logged is left out, not counted as 0") to calories: a day missing a macro has *unknown*
   calories, not calories computed as if that macro were 0. Using one day-set for all four also
   means the numbers always agree: avg calories = 4·avg protein + 4·avg carbs + 9·avg fat.
   It's built generically as Nutrition's `item_requires` config (D3, D10). The SQL is in Step 2.

### A.4 interpretation check (resolved in round 6)

Round 5 asked whether "these averages" meant calories only or all four numbers. The user's answer
was **all four, using one day-set**. Nothing is pending here. See A.4 above, D10 and Section 9.

**Decided in this plan; no input needed unless you disagree:**
- Calories is **purely derived and never stored** (confirmed by the user in round 6). Nothing
  writes a `calories` key to `item.data`, and no column or event holds it. It's computed fresh at
  read time from that day's protein_g/carbs_g/fat_g, every time the report is loaded (D10).
- Calories is computed **in the RPC**, from config (D10). It is not hardcoded in SQL or C#.
- Weekly calories = the **average of each day's calories** (each complete day's 4p + 4c + 9f)
  (D10).
- A day where a field was never logged is **left out of that field's average**, not counted as 0
  (D9). For Nutrition, A.4 goes further: a day missing *any* of the three macros is left out of
  **all four** averages (`item_requires`, D3/D10).
- Negative logged values (for example a typo'd `-5` from a chat correction) are **not** rejected.
  This is a documented limitation (Section 5), not a code change.
- **Page scope (a judgment call; flag it if it's wrong).** The page has four value cards and a
  `‹ This week ›` stepper for moving between weeks. The stepper isn't one of the four numbers, but
  without it last week's finished averages can't be seen at all, and on a Monday morning the page
  would show an almost empty week. The trend charts, trend-length chips, per-week list and per-card
  day counts are gone. Dropping the stepper too would delete about 15 lines from Step 6c and its
  phone check (Step 8 check 4.3).

**Restate at the implementation re-ask (not an open question).** The user chose both "no
days-included count" (round 5) and "one day-set for all four numbers" (round 6) in separate
rounds. Together they mean a day missing even one macro vanishes from every card with nothing on
the page saying so, and an average may rest on one or two days without that being visible (in the
Step 4b fixture, 2 of 6 days count). When asking to start implementation, state this combined
effect in one sentence. If the user wants visibility back, the cheapest fix is a client-only basis
line ("avg per day · 2 days") reading `field_counts`, which the RPC already returns; that would be
a scope change made then, not now.

Also ask for explicit go-ahead at each of these steps:
- implementation starting at all (the re-ask above);
- Step 4's `supabase db push --linked`, which changes the shared dev database;
- Step 8's push to `main`, which triggers `deploy-pages.yml`.

---

## 0. Ground truth (checked read-only against dev and the repo, 2026-11-15)

### 0.1 The Nutrition Tracker data model as built

- **One item per day** (`item_label = 'meal date'`). It moves forward through
  breakfast → brunch → lunch → linner → dinner (`sequence_order` 1–5). All five stages use the same
  checklist keys (`protein_g, carbs_g, fat_g, fiber_g, sugar_g, weight_lbs`). The report reads
  only the first three. The other three are still logged and still snapshotted by Step 1, but
  nothing reports them.
- **`move_stage` (`20261113000000`) clears the shared keys from `item.data` on every forward move**,
  including forward skips. Backward moves clear nothing. So right after a forward move, `item.data`
  holds only the current stage's values.
- **Values are running totals per stage, not deltas.** Scan Plate writes `existing + scanned`.
  Chat corrections write absolute values through the agent's untyped `update_data` patch, so a
  value *can* arrive as a JSON string.
- **`fiber_g` is inside `carbs_g`.** Scan-plate enforces fiber + sugar ≤ carbs + 1
  (`supabase/functions/scan-plate/index.ts:79`). The only effect on this plan is the known
  approximation in D10: Atwater 4 kcal/g on total carbs.
- **`enforce_stage_order = false`** (the column default), so forward skips are allowed.
- Nutrition Tracker is in the **same account** as `Joe's Auto Repair`.
- So a day's total can't be read from `item.data` alone: for any day past Breakfast, that drops
  every earlier meal. D1 handles this.

Live dev data, one Nutrition item per day (all in the ISO week starting Mon 2026-11-09, Chicago):

| item | created_at (UTC) | stage now | moves |
|---|---|---|---|
| `a831e45f` | 2026-11-13 03:53 (= 11-12 21:53 Chicago) | dinner | 4 forward |
| `b173bc11` | 2026-11-13 12:45 | breakfast | none |
| `fdd1665e` | 2026-11-14 13:20 | breakfast | none |
| `8c4775d6` | 2026-11-15 14:30 | lunch | 2 forward, 22:25 UTC |

`8c4775d6`'s moves happened before Step 1 exists, so its earlier meals are gone the same way
`a831e45f`'s are (D2). All four items hold all three of protein/carbs/fat (re-checked 2026-11-15),
so the A.4 rule excludes none of them.

Other facts the plan relies on:
- Every stored macro is a JSON number today.
- The mechanic job with money stores `estimate_amount` = 300 and `invoice_amount` = 500 as numbers.
- No two mechanic stages share a key, so `move_stage` never clears anything there.
- `item_events.seq` is a global bigserial, so it never ties.
- `items.stage_id` is NOT NULL, so `from_stage_id` is never null on `stage_changed`.
- Nothing in the web app or `agent-loop` reads `item.stage_changed`'s `data` today
  (`GetItemEventsAsync` has no callers; `GetNotesAsync` filters to `item.note_added`).
- `WorkflowSummary` is `record WorkflowSummary(string Id, string Name, string ItemLabel)`
  (`web/Services/WorkflowApiClient.cs:6`).

### 0.2 How SQL runs against dev

- There is no `psql` against dev. Use `supabase db query --linked`, inline or with `-f <file>`. It
  goes through the Management API, so there are no `\set`/`\gset` variables.
- `scripts/phase*_test.py` are hard-wired to the local stack and can't target dev.
- So every write-path check is **one self-contained `do $$ … $$` block** that always ends in
  `raise exception`: every write rolls back, and the "result" is the error message. A message
  starting with `PASS` (or `DRY RUN`) is success, even though the CLI exits non-zero.
- The local Supabase stack (`supabase_db_workflow-app` container) is behind dev (last applied
  migration `20261016130000`). Every later migration except `20261023120000` applies cleanly
  inside a transaction (that one's `chat_messages` table already exists locally). **Earlier
  versions** of the Step 2 SQL and the Step 4b script (round-4 form) were run that way on
  2026-11-15, inside `begin … rollback`, and passed. **This round's versions have not been run.**
  Step 4.0 makes running them mandatory.

### 0.3 The architectural rule this plan follows

- One generic page or RPC per concern.
- Workflow-specific behaviour lives in data and config (`stages.checklist` /
  `optional_checklist` jsonb), not in per-workflow code.
- The page has two existing kinds of exception: branching on `item_label == "job"` for display,
  and capability gates keyed on well-known field names (`vin`, `protein_g`, `scheduled_at`, the
  `_g`/`_lbs` unit suffixes).
- **This plan adds no new exception of either kind.** The Report is gated only on
  `workflows.report_config` being non-null. Every per-field behaviour (label, unit, both
  aggregation levels, derived-field weights) and the per-item inclusion rule (`item_requires`) is
  read from that config. In particular, the Atwater
  factors 4/4/9 live in Nutrition's config row, not in SQL or C#. Narrowing Nutrition's report to
  four numbers is a **config** change. The engine keeps its general capabilities (any number of
  fields, `sum`/`avg`/`last` at both levels, `day`/`week`/`month` periods).

### 0.4 Styling tokens in use

- `--app-accent` (`#2b88d8`).
- Buttons use `Appearance="ButtonAppearance.Primary"`.
- Fluent UI Blazor v5.0.1.

## 1. What gets built

1. **Snapshot on clear.** `move_stage` records the values it clears inside its own
   `item.stage_changed` event (`data = {"cleared": {...}}`). Unchanged.
2. **Config.** A nullable `workflows.report_config jsonb` sets the period, the fields to report,
   each field's **two independent aggregation settings** (`item_agg`, `period_agg`), optional
   **derived fields** (a weighted sum of other fields, e.g. calories), and an optional
   **`item_requires`** list (an item missing any listed field is left out of every field). `null`
   means no report.
3. **Read path.** One `report_series` RPC (security invoker) returns per-period values and
   per-field counts, in a caller-supplied timezone. Snapshots are deduped per
   (item, departing stage, field).
4. **UI.** A generic page `/workflow/{WorkflowId}/report` (`WorkflowReport.razor`), linked from
   `WorkflowDetail`'s list view when `report_config` is set. It shows one value card per configured
   field for the focused period, plus a period stepper.
5. **Content.** Only Nutrition Tracker gets a `report_config`: weekly, four fields. Calories is
   derived (4p + 4c + 9f per day, averaged). Protein, carbs and fat are each summed within a day
   and averaged across the week. All four average over the same days: those with all three macros
   (`item_requires`). The mechanic gets a rolled-back dry run only.

**Removed in earlier rounds:** goals entirely. That means the `report_goals` table,
`goal_direction`, the goal-in-effect rule, the goal UI, and `GetReportGoalsAsync`/
`AddReportGoalAsync`. **Removed this round:** see Section 8.

## 2. Decisions

### D1. Per-stage values are captured at write time and deduped per stage at read time

**Write side.** Before `move_stage` deletes the shared keys, it builds
`jsonb_object_agg(k, data->k)` over the shared keys that are present and stores it as
`{"cleared": …}` in the `stage_changed` event. When nothing is cleared, `data` stays null, so the
mechanic and Feature Pipeline log exactly what they do today. The capture lives in the RPC, so it
covers both the UI's Done button and the agent's `move_stage` tool. **Without this, a day's earlier
meals are erased as the item moves through stages, and every per-day total this feature reports is
wrong.**

**Read side.** For each item and each base (non-derived) field `k`:
1. **Segments.** A segment is a `(stage, seq, value)` triple from one of two sources: each cleared
   snapshot, keyed on `from_stage_id` with the event's `seq`; and the live value, keyed on
   `items.stage_id` with `seq = +∞`.
2. **Dedupe.** Keep the highest-`seq` segment per `(item, stage, k)`.
3. **Combine** the survivors with the field's **`item_agg`** (D9).

Each stage the item has been at contributes the value the field held the last time the item was
there.

**Why `from_stage_id`, not `to_stage_id`.** Two departures from the same stage can land on
different stages when forward skips are allowed. Step 4b check 4 tells the two keyings apart
(60 vs 75).

**Residual.** Backing out to an earlier stage and moving forward again without editing replaces
that stage's original snapshot with the carried-over values. Deferred (A.2, Section 6).

**Rejected alternatives:** replaying `data_changed` events (complex, re-interprets history whenever
a checklist is edited, can't tell pre-`20261113000000` moves apart); per-stage namespaced keys
(break the shared-checklist design); a separate snapshot table (`stage_changed.data` already
exists and is unused).

### D2. No backfill

`a831e45f`'s moves have no `cleared` data, so local 11-12 reports Dinner's live values only.
`8c4775d6` (11-15) reports Lunch's live values only. Any further forward move made before Step 4's
push loses data the same way. The migration comment says so.

### D3. Config: `workflows.report_config jsonb`

Top level:

| property | values | default | validated by CHECK | notes |
|---|---|---|---|---|
| `period` | `day`, `week`, `month` | required | yes | ISO weeks (Monday start) = `date_trunc('week')`. Nutrition sets `week`. |
| `fields` | non-empty array | required | yes (each element too, see below) | Display order = array order. |
| `item_noun` | text | the workflow's `item_label` | no (UI-only) | Used in the basis line "avg per day". Nutrition: `"day"` (its `item_label` is `meal date`). |
| `item_requires` | non-empty array of strings, each the `key` of a **base** field in `fields` | absent (no requirement) | yes (`private.report_item_requires_valid`) | **Added in round 6.** An item without a non-null value for every listed key is left out of **every** field's aggregation (it still counts in `item_count`). Nutrition: `["protein_g", "carbs_g", "fat_g"]` (A.4). Duplicate entries are harmless and allowed. |

Each `fields[]` element is **either a base field or a derived field**:

| property | base field | derived field | notes |
|---|---|---|---|
| `key` | required, non-empty string, unique | required, non-empty string, unique | Base: a `data.*` key. Derived: an output name only. |
| `item_agg` | **required**: `sum`, `avg`, `last` | **must be absent** | How one item's per-stage values combine (D9). |
| `period_agg` | **required**: `sum`, `avg`, `last` | **required**: `sum`, `avg`, `last` | How a period's item values combine (D9). |
| `weights` | absent | **required**: non-empty object of `{base_key: number > 0}` | Each key must name a *base* field in the same array. No derived-of-derived. |
| `label` | text, default: key humanized | same | |
| `unit` | text, default `""` | same | No fallback to the `_g`/`_lbs` suffix convention. |
| `unit_position` | `prefix`/`suffix`, default `suffix` (UI-only) | same | |

**Removed in round 5 (all UI-only, never validated by the CHECK):** `show_count` and `count_label`
(the "Days included" card), `split` (the % split), and `hidden`. `hidden` existed only so
protein/carbs/fat could appear inside the split instead of as cards; now they are cards. Because
the CHECK never looked at these properties, removing them changes neither the validator nor its 27
test cases. A stale config that still contains them passes the CHECK, and the client parser ignores
them. Adding any of them back later is a client-only, additive change.

**Why both aggregation settings are required, with no default.** With two levels, a silently
defaulted level is exactly the bug class D9 fixes. One example is a once-a-day reading getting
summed across meals. Every field states both levels, and the CHECK enforces it. This also rejects
any stale config still using the old single `agg` key.

**What the CHECK validates, and what it doesn't.** It validates everything the RPC relies on:
- object shape;
- `period`;
- non-empty `fields`;
- each element's `key`/`item_agg`/`period_agg`/`weights` rules above;
- unique keys;
- `item_requires`, when present (round 6).

It does not validate the UI-only properties (`label`, `unit`, `unit_position`, `item_noun`). The
client parser defaults those without throwing.

Why the config lives on `workflows`, as jsonb:
- It follows the `checklist` precedent (static, migration-authored metadata).
- A report spans stages, so it belongs to the workflow.
- The nullable column doubles as the on/off switch.

Rejected: a child table, and hints on `checklist` entries.

### D4. (Removed: goals.)

### D5. Grouping uses `created_at` in the viewer's timezone

- `period_start = date_trunc(period, created_at AT TIME ZONE p_tz)`.
- `p_tz` comes from `Intl.DateTimeFormat().resolvedOptions().timeZone`.
- `ItemDisplayName` switches to `CreatedAt.ToLocalTime()` so the list and the report agree. That
  name is also what goes to `agent-loop` as `selected_item_display_name`, and it becomes more
  correct there too.
- Known gap, deferred: for mechanic revenue, bucketing by invoice date might fit better.

### D6. Aggregation is one server-side RPC

- `report_series(p_workflow_id, p_from, p_to, p_tz)` returns one row per non-empty period:
  `(period_start date, item_count bigint, field_values jsonb, field_counts jsonb)`.
  - `field_values`: `{key: number}` for every configured field (base and derived) that has a
    non-null period value.
  - `field_counts`: `{key: n}`, how many items contributed a non-null value to that field (the
    denominator of an `avg`).
- `item_count` counts every item in the period, including ones with no data.
- **`item_count` and `field_counts` stay in the RPC but are not displayed.** They're the generic
  engine's output and cost nothing to keep, and Step 4b asserts on `field_counts` (it's the most
  direct check that A.4 (a) excludes partial days). The client doesn't parse them (Step 5).
- **`field_shares` (the % split) is removed** from the return type, along with the SQL that
  computed it.
- Security invoker; RLS scopes it like `search_items`.
- Values go through `private.jsonb_numeric`: numbers pass through; `"$1,250.00"`/`"30"`-style
  strings are parsed; anything else becomes null. The string branch stays because the agent's
  `update_data` patch is untyped. Step 4b tests it (check 0, and check 5 feeds a real `"25"`).

### D7. UI: one generic page, value cards only, no charts

- Only Fluent components already used in `WorkflowDetail`: `FluentCard`, `FluentStack`,
  `FluentButton`, `FluentLink`, `FluentSpinner`, `FluentMessageBar`.
- No SVG trend and no chart library. The trend was dropped this round along with everything else
  beyond the four numbers.

### D8. The agent loop is untouched

Chat access to report numbers is out of scope. A chat/Q&A alternative to this page was discussed
with the user and **explicitly set aside**. So there is no chat scope, no agent tool, and no
preset-question mechanism.

### D9. Two independent aggregation levels: `item_agg` and `period_agg`

One item's per-stage values and one period's item values are combined separately, because they
answer different questions:

| field | within a day (`item_agg`) | across the week (`period_agg`) |
|---|---|---|
| protein / carbs / fat | `sum`: a day's total is breakfast + … + dinner | `avg`: average daily intake |
| calories (derived) | none; computed per day from that day's p/c/f (D10) | `avg`: average daily calories |

Nutrition no longer uses `last`, but the engine keeps it at both levels. `item_agg: last` is how a
once-a-day reading (such as a weight) or a single job amount (Step 7) would be reported. Step 4b
check 10 tests both `last` levels with a throwaway config.

**Naming.** `item_agg` / `period_agg`, not `within_day_agg` / `across_days_agg`. The engine is
generic: for the mechanic an item is a job, not a day, and the period may be a day, week or month.

**Semantics.**
- `item_agg` combines the deduped per-stage segments (D1).
  - `sum` and `avg` ignore null segments.
  - `last` takes the non-null value with the highest `seq`. The live value counts as the latest.
  - `last` needs no tie-break: `seq` never ties (Section 0.1), and the live segment's sentinel
    `seq` appears at most once per (item, field).
- `period_agg` combines the period's item values.
  - `sum` and `avg` ignore items whose value is null (the field was never logged that day).
  - `last` takes the non-null value of the latest-created item. A tie on `created_at` is broken by
    the greater `items.id` (`order by its.created_at desc, its.id desc`). This is arbitrary but
    deterministic.
  - So `avg` means "average over the days that have a value" (and, when `item_requires` is set,
    that pass it).
- Each level applies exactly its configured aggregate, once. Nutrition's `avg` runs only at the
  period level, over per-day sums. There is no hidden average-of-averages (this settles round-2
  sanity-check finding #6), and the page has no multi-period summary that could create one.

**Rejected alternatives:**
- *Keep one `agg` and infer the other level from the key or unit* (e.g. `_lbs` → `last`). That's a
  field-name gate, against Section 0.3.
- *A single compound value* (`"agg": "sum/avg"`). Two plain properties are easier to validate in
  the CHECK and to read.
- *Defaults for either level.* See D3.

### D10. Calories is computed in the RPC, from config

**Shape.** A derived field: `{"key": "calories", "label": "Calories", "unit": "kcal",
"period_agg": "avg", "weights": {"protein_g": 4, "carbs_g": 4, "fat_g": 9}}`. The `weights` map is
just how calories is computed from grams. Nothing computes or displays a percentage breakdown.

**Never stored (settled; confirmed by the user in round 6).** Calories exists only as an output of
`report_series`. No code path writes a `calories` key to `item.data`, Scan Plate and the agent
keep writing grams only, and nothing caches the computed value. Every report load recomputes it
from the stored protein_g/carbs_g/fat_g. So a corrected macro is reflected in calories on the next
load, and there's no stored calories value that could drift from the grams.

**Computation, in `report_series`:**
1. **Per item:** `calories = Σ weight_k × item_value_k` over the components, **only if the item has
   a non-null value for every component**. Otherwise the item has no calories value and is left
   out of the calories average. An item missing fat has no calories, not 4p + 4c.
2. **Item gate (`item_requires`, round 6):** an item that lacks any key listed in `item_requires`
   is dropped from every field, base and derived. Nutrition lists exactly calories' three
   components, so a day contributes to all four numbers or to none.
3. **Per period:** `period_agg` (`avg`) over the remaining items' calories, which gives **average
   daily calories**. Protein, carbs and fat are averaged over the same remaining items.

**Partial days: A.4 resolved as (a).** Earlier rounds offered three options:
- **(a)** only days with every component count toward calories;
- (b) keep partial days and show a completeness count;
- (c) count partial days with whatever macros they have.

The user chose **(a)**. The reason: a day needs all three macros to have a known calorie total.
Counting a missing macro as 0 would break the rule D9 already applies to plain fields ("never
logged is left out, not counted as 0"). Options (b) and (c) and their SQL are gone from this plan.

*Consequence:* the rule is **engine-wide** for every derived field, with no config switch: a
derived field's per-item value needs every component. That's deliberate. A positive weighted sum
with missing terms can't be trusted for any workflow. If a future derived field really wants
partial sums, it would add an explicit, CHECK-validated property at that point.

*Effect on base fields (round 6): the filter is uniform across all four numbers.* The user
settled that a partial day is left out of the protein, carbs and fat averages too, not just
calories. All four numbers use one day-set, so they always agree: over the same days,
avg calories = 4·avg protein + 4·avg carbs + 9·avg fat exactly (4b check 6 asserts this). Under
round 5's interim calories-only rule, they could disagree, for example 595 implied vs. 600 shown
in the 4b test week.

*How the uniform filter is expressed: a top-level `item_requires` list, not a side effect of
`weights`.* Nutrition's config sets `"item_requires": ["protein_g", "carbs_g", "fat_g"]`. The RPC
drops any item missing one of those from every field (Step 2's `required`/`kept` CTEs). Rejected
alternatives:
- *Implicit: "an item missing any component of any derived field is dropped from every field."*
  It needs no config or validator change (about 25 fewer lines and 6 fewer test cases). But adding a
  derived field would then silently change the base fields' numbers. For example, a future mechanic
  `profit` field would drop jobs with no estimate from the invoiced total. An explicit list keeps
  that coupling visible and opt-in.
- *Implicit: "an item must have every configured base field"* (round-6 sanity check, finding 1).
  For Nutrition today it gives the identical result with no new property or validator. Rejected
  by the architect review: as an engine-wide rule it would change other configs' numbers (the
  Step 7 mechanic dry run would drop jobs with an invoice but no estimate from the invoiced total;
  check 10's weight/protein config would drop Mon), so it would have to be opt-in anyway, e.g. a
  boolean. A boolean couples the day-set to whatever base fields are displayed: adding a
  rarely-logged `weight_lbs` card to Nutrition later would silently drop every day without a
  weigh-in from the macro averages. The explicit list costs one small validator and 6 test
  cases, and keeps "which fields gate the day" separate from "which fields are shown".
- *Hardcoding the three macro keys in SQL or C#:* a field-name gate (Section 0.3).
- *Filtering client-side:* the client gets only period aggregates and can't see days.
- *A per-field `requires` property:* one shared day-set is the point. Per-field lists could
  disagree, which would reintroduce the mismatch.

The D10 "every component required" rule for derived fields (step 1) stays engine-wide. For
Nutrition, `item_requires` makes it redundant, but a workflow with a derived field and no
`item_requires` still needs it.

**Why average the per-day calories, rather than derive calories from the averaged grams.**
- Daily calories is a per-day quantity, and "average daily calories" is literally the mean of the
  daily figures.
- Deriving from averaged grams (`4·avg(p) + 4·avg(c) + 9·avg(f)`) gives the same answer when every
  day has all three macros. When days differ, it mixes denominators. For Nutrition, `item_requires`
  makes every counted day have all three, so the two methods now agree exactly. The engine still
  computes per day because the "every component required" rule is decided day by day for any
  workflow.
- Per-day computation is also the only way to apply the "every component required" rule, since
  that rule is decided day by day.

**Why in the RPC, not in Blazor.**
- Correctness: step 1 needs per-day values, and the RPC returns period aggregates only.
- Architecture: hardcoding 4/4/9 in SQL or C# would be a Nutrition-specific field-name exception
  (Section 0.3). As config, any workflow can declare a weighted-sum field.

**Rejected:**
- *Client-side calories from the RPC's averaged protein/carbs/fat:* see above.
- *A hardcoded `calories` column in the RPC:* that's a field-name gate.
- *A general expression language for derived fields:* far more than a weighted sum needs.

**Constraints, deliberately narrow.** Weights must be numbers > 0, and components must be base
fields (no derived-of-derived). The original reason for "> 0" was that shares are meaningless with
negative weights. The split is gone, but the constraint stays for two reasons. Positive weighted
sums are the only derived kind this engine supports, and the "every component required" rule is
justified for exactly that kind. Keeping it also leaves the original 27 validator cases unchanged.
Relaxing it (e.g. for a profit field) is a future plan.

**Known approximation.** Atwater 4 kcal/g on *total* carbs counts fiber at 4 kcal/g (it's closer to
~2). This matches the user's spec and scan-plate's own plausibility check (`index.ts:120`), and is
not corrected here.

## 3. Steps

### Step 1. Migration: `move_stage` snapshots what it clears

**Unchanged.** File: `supabase/migrations/20261115000000_move_stage_records_cleared_values.sql`.
This is the full, literal file. It is `20261113000000`'s body with exactly three changes, marked
`-- NEW`/`-- CHANGED`.

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
-- No backfill: Nutrition items that moved forward before this migration (one test-like day whose
-- moves straddle 20261113000000's rollout, and 2026-11-15's day) recorded nothing about what those
-- moves cleared, so it is unknowable -- those days report their live (current-stage) values only.
-- Body is otherwise identical to 20261113000000, including the enforce_stage_order check that
-- 20261016130000 once silently dropped.

create or replace function public.move_stage(p_item_id uuid, p_to_stage_id uuid)
returns public.items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item public.items;
  v_from_stage uuid;
  v_enforce boolean;
  v_from_seq integer;
  v_to_seq integer;
  v_from_checklist jsonb;
  v_to_checklist jsonb;
  v_shared_keys text[];
  v_cleared jsonb;  -- NEW
begin
  select * into v_item from public.items where id = p_item_id for update;
  if not found then
    raise exception 'item not found';
  end if;

  v_from_stage := v_item.stage_id;

  select enforce_stage_order into v_enforce
  from public.workflows where id = v_item.workflow_id;

  select sequence_order, checklist into v_from_seq, v_from_checklist
  from public.stages where id = v_from_stage;
  select sequence_order, checklist into v_to_seq, v_to_checklist
  from public.stages where id = p_to_stage_id;

  if v_enforce then
    if v_from_seq is not null and v_to_seq is not null
       and v_to_seq > v_from_seq
       and v_to_seq != v_from_seq + 1 then
      raise exception 'forward skip from stage % (seq %) to stage % (seq %) is not allowed when enforce_stage_order is true',
        v_from_stage, v_from_seq, p_to_stage_id, v_to_seq;
    end if;
  end if;

  if v_from_seq is not null and v_to_seq is not null and v_to_seq > v_from_seq then
    select array_agg(elem) into v_shared_keys
    from jsonb_array_elements_text(coalesce(v_to_checklist, '[]'::jsonb)) elem
    where coalesce(v_from_checklist, '[]'::jsonb) ? elem;
  end if;

  -- NEW: capture before the update below deletes them (v_item is still the pre-update row).
  -- Only keys actually present; zero rows -> jsonb_object_agg returns null.
  select jsonb_object_agg(k, v_item.data -> k) into v_cleared
  from unnest(coalesce(v_shared_keys, array[]::text[])) as k
  where v_item.data ? k;

  update public.items
  set stage_id = p_to_stage_id,
      data = data - coalesce(v_shared_keys, array[]::text[]),
      updated_at = now()
  where id = p_item_id
  returning * into v_item;

  insert into public.item_events (item_id, event_type, from_stage_id, to_stage_id, stage_id, data)  -- CHANGED
  values (p_item_id, 'item.stage_changed', v_from_stage, p_to_stage_id, p_to_stage_id,
          case when v_cleared is not null then jsonb_build_object('cleared', v_cleared) end);

  return v_item;
end;
$$;
```

### Step 2. Migration: report config, validator, numeric helper, RPC, Nutrition content

File: `supabase/migrations/20261115010000_add_workflow_report_config.sql`

Compared with `round-4-final-plan.md`:
- The validator (`report_fields_valid`), the CHECK and `jsonb_numeric` are **byte-for-byte
  unchanged**.
- `report_series` changes in three ways:
  - the A.4 (a) `item_terms_all`/`item_terms` CTEs replace the old `item_terms`;
  - `period_terms` and `period_shares` are deleted;
  - `field_shares` is dropped from the return type and the final `select`.
- The Nutrition config is down to four fields.
- The header comments are updated to match.

Round 6 adds the following (everything else in this file is the same as round 5):
- a new function `private.report_item_requires_valid`, with its own `revoke`/`grant`;
- one more conjunct in the `workflows_report_config_shape` CHECK;
- the `required`/`kept` CTEs in `report_series`, and `item_vals` filtered to `kept`;
- `"item_requires": ["protein_g", "carbs_g", "fat_g"]` in Nutrition's config;
- matching comments.

`report_fields_valid` and `jsonb_numeric` are still byte-for-byte unchanged.

```sql
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
```

Notes:
- **Status of the SQL.**
  - **Verified earlier:** the round-3/round-4 form of this file and of the 4b script ran on the
    local stack on 2026-11-15 inside `begin … rollback` and printed `PASS`.
  - **Not yet run end to end:**
    - the `coalesce(jsonb_typeof(f -> 'key'), '')` hardening and the 27-case check 1 (both checked
      only at expression level, by the architect);
    - the A.4 (a) CTEs;
    - the shares removal;
    - the new four-field config;
    - 4b check 10;
    - everything added in round 6: `report_item_requires_valid` and the extra CHECK conjunct, the
      `required`/`kept` CTEs, `item_requires` in the config, and the 4b changes (6 new check-1
      cases, the config strip/restore, and the new check 5/6 assertions).
  - **Partially verified in round 6 (2026-11-15, local stack, `begin … rollback`).** This file's
    full SQL block was applied, and then:
    - all 33 check-1 configs were rejected as `check_violation`;
    - with the shipped Nutrition config on a 6-item fixture matching check 6's per-day values
      (live data only, no `move_stage` snapshots, run as `postgres`, not through RLS), the week
      returned `item_count` 6 and values protein 45 / carbs 60 / fat 20 / calories 600, with every
      count 2;
    - Mon alone returned `{}`/`{}`;
    - with `item_requires` stripped, Thu alone returned `{protein_g: 25}`, and the week gave protein
      43.75 (n=4) with calories still 600.
    The full 4b script (snapshots, role switching, checks 7–10) has not been run, and Step 4.0
    still requires it.
  - Step 4.0 makes the local re-run mandatory.
- **A.4 (a) mechanics.** An item is excluded from a derived field if any component has no
  `item_base` row (the component was never logged at any stage) or has a null value (logged but
  unparseable). Both cases make `item_terms_all`'s count for that item fall short of the number of
  weights. Because `jsonb_each` over an object yields each weight key once, the `derived_terms`
  count is exactly the number of components.
  - The correlated subqueries run once per row of `item_terms_all`. That's at most 3 rows per item
    for Nutrition, which is negligible at these volumes.
  - An equivalent `group by … having count(*) = …` form was considered. The CTE above was kept
    because it's the text the user approved as option (a) in `round-4-final-plan.md`.
- **`item_requires` mechanics (round 6).** `kept` counts, per item, the `item_base` rows that are
  non-null and whose key is listed, and compares that with the number of distinct listed keys.
  `item_base` has one row per (item, key), so the count can't double up. A listed macro that was
  never logged (no row) or is unparseable (null) makes the item fail. A failing item is removed in
  `item_vals`, before `period_vals`, so it's missing from every `field_values` and `field_counts`
  entry. It's still in `its`, so `item_count` still counts it, and a period where every item fails
  still returns its row (with `{}` values; the page shows "—" on every card). Without
  `item_requires`, `required` is empty and `kept` is every item, so behaviour is exactly round 5's.
  For Nutrition, `item_requires` and calories' components are the same three keys, so after the gate
  the `item_terms` every-component filter never removes anything. It's kept for workflows without
  `item_requires`.
- **Validator coverage.** Step 4b check 1 holds **33 bad configs**: the 27 from `round-4-final-plan.md`,
  unchanged, plus 6 `item_requires` cases added in round 6 (unknown key, derived-field key, empty
  array, non-array, JSON null, non-string entry). Each of the 6 has an otherwise valid `fields`, so
  only the new conjunct can reject it. Together they cover every rejection branch of
  `report_fields_valid`, `report_item_requires_valid` and the top-level CHECK.
  Each one must be rejected as `check_violation`, never as another error. The architect review
  evaluated the CHECK expression against the original 27 on the local stack (rolled back). All came
  out strictly `false`, never NULL, and a Nutrition-shaped config came out `true`. The 6 new cases
  haven't been evaluated yet (Step 4.0).
  - That run found one fragile branch. For a field with **no `key`**,
    `jsonb_typeof(f -> 'key') <> 'string'` is NULL, so the `case` fell through. The config was
    rejected only by accident: `count(distinct …)` ignores NULLs, so the uniqueness check failed.
    The `coalesce(…, '')` above makes that branch reject the field directly. Check 1's two
    missing-key cases cover it.
  - None of the 27 configs uses `split`, `hidden` or `show_count`, so removing those properties
    doesn't touch the suite.
- **Accepting a valid config** is covered in three places. The shipped four-field Nutrition config
  (with `item_requires`) must apply, and the 4b SETUP guard fails if `report_config` is still null
  or lacks the expected `item_requires`. The strip after check 1 applies the same config without
  `item_requires`. Check 10 also applies a second valid config (with `last` at both levels and no
  `item_requires`).
- **`jsonb_numeric` edge cases.**
  - A non-numeric live value still counts as that stage's latest segment, with value null. That
    stage contributes nothing, and the report doesn't fall back to an older snapshot. If every
    stage that day is non-numeric for a macro, the day has no value for it, so under A.4 it drops
    out of all four averages.
  - Negative values pass through on purpose. `jsonb_numeric` is a generic helper, and a future
    workflow may legitimately store negative amounts (refunds). See Section 5.
- **Indexes.** `items(workflow_id)` and `item_events(item_id, seq)` are enough at these volumes.
- **Components must be base fields in the same `fields` array** (the validator enforces it).
  Calories needs their per-day values, and only base fields produce those. For Nutrition the
  components are also three of the four displayed cards.

### Step 3. (Removed: the `report_goals` migration.)

### Step 4. Push and verify the database side

**4.0 Pre-push gate (local, rolled back).** All of these must be done before asking for the
`db push` go-ahead:
1. Section A has a recorded answer for A.1–A.3. (A.4 and its scope were settled in round 6, so
   there's nothing to ask about them.)
2. Re-run both files on the local stack the same way as before (Section 0.2): apply the missing
   intermediate migrations plus Step 1 and Step 2 inside `begin … rollback`, then run the 4b block.
   It must print `PASS` with "33 bad configs rejected".
   - On the local stack, the `SETUP: real Nutrition items exist before 2026-11-01` guard and the
     workflow lookups behave as on dev only if the Nutrition workflow migration (`20261112000000`)
     is among those applied. It is.

**4.1 Push.** **Needs the user's explicit go-ahead before `db push`. It changes the shared dev
database.**

```bash
cd /home/mmcbride/micah/claude/workflow-app
diff <(sed -n '/create or replace function/,$p' supabase/migrations/20261113000000_move_stage_clears_shared_fields.sql) \
     <(sed -n '/create or replace function/,$p' supabase/migrations/20261115000000_move_stage_records_cleared_values.sql)
# expect ONLY: the v_cleared declaration, the NEW capture block, and the insert's added data column/value
supabase db push --linked --dry-run   # expect exactly the two new files
supabase db push --linked
```

**4a. Read-only check against real data.** Run it right after the push, before any Nutrition item
in the week of 2026-11-09 moves forward again (a move after the push writes a snapshot, which the
cross-check below doesn't model). These go straight to SQL, not through PostgREST, so a stale
PostgREST schema cache can't show up here. It would first show up in Step 8 check 2.

```bash
supabase db query --linked "select * from public.report_series(
  (select id from public.workflows where name = 'Nutrition Tracker'),
  '2026-11-09', '2026-11-15', 'America/Chicago')"
```

Expect:
- one row, `period_start` 2026-11-09;
- `item_count` 4;
- `field_values` with **exactly four keys**: `calories`, `protein_g`, `carbs_g`, `fat_g`;
- four columns (no `field_shares`).

Then cross-check against a direct computation from live data. This is valid because no item in
that week has a `cleared` snapshot yet:

```bash
supabase db query --linked "with i as (
  select private.jsonb_numeric(data->'protein_g') p, private.jsonb_numeric(data->'carbs_g') c,
         private.jsonb_numeric(data->'fat_g') f
  from public.items
  where workflow_id = (select id from public.workflows where name = 'Nutrition Tracker')
    and date_trunc('week', created_at at time zone 'America/Chicago')::date = '2026-11-09'),
k as (select * from i where p is not null and c is not null and f is not null)
select (select count(*) from i) n, count(*) complete_days,
       avg(p) protein, avg(c) carbs, avg(f) fat, avg(4*p + 4*c + 9*f) calories
from k"
```

All four averages come from the same complete days (`k`), as A.4 requires. They must match the
RPC row, and every entry of `field_counts` (calories, protein_g, carbs_g, fat_g) must equal
`complete_days` (4 today). If they differ, first check whether any of those items has a
`stage_changed` event with non-null `data` (then the cross-check, not the RPC, is out of date).

Timezone bucketing is checked deterministically in 4b (check 7), not against real data, since all
four real items fall in one week in both UTC and Chicago.

**4b. Write-path checks.** Save as `scripts/report_series_dev_check.sql`. It's safe to re-run. Run
it with `supabase db query --linked -f scripts/report_series_dev_check.sql`.
- **Success:** an error message starting with `PASS`.
- **Failure:** anything else (`FAIL …`, `SETUP …`, or any other error). Nothing persists either way.

All test items are back-dated into the week of Mon 2026-01-05. That week predates the Nutrition
workflow, so real data never mixes into the asserted numbers (the SETUP guard checks this).

`weight_lbs` still appears in the test data. It's not reported, but it is (1) still a shared
checklist key, so it exercises Step 1's multi-key snapshot (check 2), and (2) the vehicle for check
10's generic `item_agg: last` test.

**The `item_requires` strip and restore (round 6).** Checks 2–4 test D1's per-stage snapshots and
dedupe on Mon (d_a), which only ever logs protein. Under the shipped config, `item_requires` would
drop Mon from every field and those checks would see nothing. D1 doesn't depend on
`item_requires`, so the script saves the shipped config, strips `item_requires` right after check 1
(still as the CLI role), runs checks 2–5 without it, and restores the shipped config at the start
of check 6. Checks 6–7 then run against the exact shipped config. The alternative was to give Mon
carbs and fat. It was rejected because that would change check 2's snapshot assertion, make Mon a
complete day (so the week would have just one partial day), and make Thu's string-typed `"25"`
contribute to no asserted number. The strip costs one extra `reset role`/`set local role` round
trip, of the same kind check 10 already uses.

```sql
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
```

How check 6's expected numbers come about (the test week, Chicago):

| day | protein | carbs | fat | all three? (counted) | calories |
|---|---|---|---|---|---|
| Mon (d_a) | 40 + 20 = 60 (breakfast + brunch snapshots, after dedupe) | — | — | no: dropped from all four | — |
| Tue (d_b) | 40 | 40 | 20 | yes | 500 |
| Wed (d_c) | — | — | — | no: dropped from all four | — |
| Thu (d_d) | 25 (string `"25"`) | — | — | no: dropped from all four | — |
| Fri (d_e) | 50 | 80 | 20 | yes | 700 |
| Sun 21:00 (d_f) | — | — | — | no: dropped from all four | — |
| **week (Tue + Fri only)** | **45** (n=2) | **60** (n=2) | **20** (n=2) | | **600** (n=2) |

- **The four numbers agree exactly:** 4·45 + 4·60 + 9·20 = 180 + 240 + 180 = 600. The script
  asserts this identity directly as well as the four values.
- Every `field_counts` entry is 2: one shared day-set.
- `item_count` is 6. It counts every item in the period, including the empty and the partial days
  that `item_requires` dropped. It's returned but not displayed.
- `field_values` has exactly four keys. `weight_lbs` is in the test data but not in Nutrition's
  config, so it must not appear.
- Values the FAIL message names, so a regression is easy to identify:
  - protein 43.75 over 4 days: round 5's interim calories-only filter. With that filter, Mon and
    Thu counted toward protein, and 4·43.75 + 4·60 + 9·20 = 595 ≠ 600. That mismatch is what round
    6 removes.
  - calories 385 over 4 days: option (c), partial days counted with the macros they have (Mon 240
    and Thu 100 included).
- A one-day query on Mon alone returns `{}` for both `field_values` and `field_counts`. That shows
  Mon's protein is excluded too, not just its calories.
- Thu's string `"25"` is parsed into a reported number in check 5, while `item_requires` is
  stripped. Under the shipped config, Thu is dropped (it has no carbs or fat).

How check 10's expected numbers come about:
- Mon's weight is 180 (breakfast snapshot) then 181 (live at lunch). `last` gives 181, where `sum`
  would give 361 and `avg` 180.5. Tue is 178. `period_agg: avg` over the two gives 179.5, with
  n = 2.
- `protein_g` with `period_agg: last` takes the latest-created item that has a value. Sun (d_f)
  has none, so it's Fri: 50. This is the first test of `period_agg: last` anywhere in the plan.
- Check 10's throwaway config has no `item_requires`, so this also covers the "absent" path: the
  CHECK accepts it, and the RPC keeps every item. Mon's weight counts even though Mon has no carbs
  or fat. The numbers are the same as in round 5.

Notes:
- Each `FAIL` names its check and prints actual values.
- Each nested `exception when check_violation` rolls back only its own subtransaction. `FAIL`
  raises are P0001, which those handlers don't catch, so they propagate.
- Check 9's handler re-raises anything that isn't a `forward skip…` error.
- The CHECK probes (check 1), the `item_requires` strip after check 1, check 6's restore and check
  10's config swap all run as the CLI's role, so they don't depend on `workflows_update` RLS. All
  of those configs pass the CHECK. Check 10's config has only non-empty string keys and valid
  `item_agg`/`period_agg` values, with no weights and no `item_requires`.
- **Fallback** if the Management API refuses `set local role` or `reset role` inside `DO`
  (Section 4): run the same file in the dashboard SQL editor. If that's refused too, Step 8 check 4
  covers checks 2–3 on real data.

### Step 5. Client API (`web/Services/WorkflowApiClient.cs`)

**New records:**

```csharp
// Generic Report (2026-11-15) -- parsed from workflows.report_config; see
// 20261115010000_add_workflow_report_config.sql for the shape. ItemAgg is null for a derived field
// (Weights non-null); both aggregation levels are required by the DB CHECK.
public record ReportField(string Key, string Label, string Unit, bool UnitPrefix,
    string? ItemAgg, string PeriodAgg, IReadOnlyDictionary<string, double>? Weights);
public record ReportConfig(string Period, string? ItemNoun, List<ReportField> Fields);
public record ReportPeriodRow(DateOnly PeriodStart, Dictionary<string, double> Values);
```

`ReportPeriodRow` carries only what the page displays. The RPC's `item_count` and `field_counts`
columns are not parsed. Adding them later is additive.

**Changed: `WorkflowSummary`.** Trailing optional parameter:
`public record WorkflowSummary(string Id, string Name, string ItemLabel, ReportConfig? Report = null);`.
- `GetWorkflowAsync` adds `report_config` to its `select` and parses it with a private
  `ParseReportConfig(JsonNode?)`.
- `GetWorkflowsAsync` is unchanged; its 3-argument construction still compiles.

**`ItemLabelPlural` is new code in the report page.** In `WorkflowDetail.razor` it's a private
property (`ItemLabelSingular` + `"s"`, lines 477–480). `WorkflowReport.razor` gets its own copy of
the same expression. Don't look for a shared helper (none exists), and keep the two identical.

**`ParseReportConfig` rules.** The CHECK guarantees the RPC-relevant shape, so the parser is a
defensive mirror. It is never a second source of aggregation defaults. Nothing throws.

| input | result |
|---|---|
| null node | `null` |
| `item_noun` missing or not a string | `ItemNoun = null`; the basis-line noun falls back to the workflow's `item_label` |
| field with missing or non-string `key` | field skipped |
| field `period_agg` not `sum`/`avg`/`last` | field skipped |
| field with `weights`: object of numbers → `Weights`, `ItemAgg = null` | otherwise skipped |
| field without `weights`: `item_agg` not `sum`/`avg`/`last` | field skipped (no default) |
| `label` missing | key humanized: `_` → space, first letter upper-cased; a trailing `_g`/`_lbs` token is dropped |
| `unit` missing | `""` |
| `unit_position` exactly `prefix` | `UnitPrefix = true`, else `false` |
| any other property (e.g. `item_requires`, which only the RPC uses, or a stale `split`, `hidden`, `show_count`) | ignored |

**New method:** `GetReportSeriesAsync(string workflowId, DateOnly from, DateOnly to, string tz)`:
POST `/rest/v1/rpc/report_series`, same pattern as `SearchItemsAsync`. Dates go out as
`yyyy-MM-dd`. Reads `period_start` and `field_values`. Each `field_values` entry is read as a
double, and any entry that isn't a JSON number is skipped. Other columns are ignored.

**Comment-only change on `GetItemEventsAsync`** (no callers today): since `20261115000000`,
`item.stage_changed` events carry `data = {"cleared": {...}}`. Any future replay of events to
derive per-key values must filter to `item.created`/`item.data_changed`, otherwise a cleared
snapshot gets mistaken for a patch.

### Step 6. UI

**6a. `web/wwwroot/js/timezone.js` (new).** Contents:
`window.getTimeZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone;`. Load it in
`index.html` with `<script src="js/timezone.js"></script>`, next to `focus.js`.

**6b. `WorkflowDetail.razor`: two small edits, no new branches.**
1. In the list view, after the Show/Hide closed link:

   ```razor
   @if (_workflow?.Report is not null) { <FluentLink Href="@($"workflow/{WorkflowId}/report")" Class="back-link" Style="margin-left:16px;">Report</FluentLink> }
   ```

   The `Href` is relative, so the Pages subpath and the `404.html` redirect apply unchanged.
2. In `ItemDisplayName`, change `{item.CreatedAt:yyyy-MM-dd}` to
   `{item.CreatedAt.ToLocalTime():yyyy-MM-dd}`, with a one-line comment that it now matches the
   report's local-day bucketing.

**6c. `web/Pages/WorkflowReport.razor` (new).**

Directives: `@page "/workflow/{WorkflowId}/report"`; inject `WorkflowApiClient` and `IJSRuntime`;
`@using System.Globalization` (for `ISOWeek`).

**Period arithmetic.** Pure static helpers on `DateOnly`, matching the RPC's `date_trunc`:

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
    "month" => new DateOnly(d.Year, d.Month, 1),
    _ => d,
};

static DateOnly NextPeriod(string period, DateOnly p) => period switch
{
    "day"   => p.AddDays(1),
    "week"  => p.AddDays(7),      // p is always a Monday; DateOnly has no DST
    "month" => p.AddMonths(1),    // p is always the 1st, so AddMonths never clamps
    _ => p.AddDays(1),
};

static DateOnly PrevPeriod(string period, DateOnly p) => period switch
{
    "day"   => p.AddDays(-1),
    "week"  => p.AddDays(-7),
    "month" => p.AddMonths(-1),
    _ => p.AddDays(-1),
};
```

(`AddPeriods` from `round-4-final-plan.md` is gone. It only computed the start of the multi-period trend
range.)

**Focused period and range.**
- `current = PeriodStart(period, today)`. The **focused** period `F` starts at `current`.
- A stepper `‹ This week ›` moves `F` back or forward one period (`PrevPeriod`/`NextPeriod`). `›`
  is disabled when `F == current`. The label is "This week" when `F == current`, else "Week of
  Nov 2" (`day`: "Nov 2"; `month`: "November 2026").
- Fetch range: `from = F`; `to = min(NextPeriod(period, F).AddDays(-1), today)`. If the user
  picks A.1's alternative, `to` becomes `yesterday` when `F == current`. When that makes
  `to < from` (Monday of the current week), skip the call and render "—" everywhere.

**Load sequence:**
1. `GetWorkflowAsync`. If `Report` is null, show "This workflow has no report configured." and a
   back link.
2. `tz = await JS.InvokeAsync<string>("getTimeZone")`; on exception, `"UTC"`.
3. `today = DateOnly.FromDateTime(DateTime.Now)` (WASM uses the browser's zone).
4. Compute `from`/`to` and call `GetReportSeriesAsync`. Re-run this step when the stepper
   changes. The result has zero or one row (the range is exactly one period). **No row, or a
   missing key, means "no data" (shown as —), not 0.**

**Rendering.** Single column, phone-first, top to bottom:
- **Header:** back link `← {ItemLabelPlural}` (the page's own copy; see Step 5) to
  `workflow/{WorkflowId}`; `ThemeToggleButton`; `<h1>{workflow.Name} report</h1>`.
- **Stepper.**
- **One `FluentCard` per field, in config order.** For Nutrition: Calories, Protein, Carbs, Fat.
  - **Value line:** label, then the focused row's value with unit ("1,850 kcal", "43.8 g"), or
    "—".
  - **Basis line:** from `PeriodAgg`, with `noun = ItemNoun ?? item_label`: `avg` → "avg per
    {noun}" ("avg per day"); `sum` → "total"; `last` → "latest". It shows no day count, because
    the user asked for no counts on the page.
- Nothing else: no split, no trend, no chips, no per-week list, no count card.

**Number formatting.** Invariant culture throughout. Values use `0.#`; `kcal` uses `N0`; a
`$`-prefixed value uses `N0` when whole and `N2` otherwise.

### Step 7. Mechanic dry run (self-rolling-back `DO` block)

Save as `scripts/report_mechanic_dry_run.sql`. Run it with
`supabase db query --linked -f scripts/report_mechanic_dry_run.sql`. Expected output: an error
starting with `DRY RUN (rolled back):`, followed by the weekly rows.

```sql
do $$
declare v_mech uuid; v_rows jsonb;
begin
  select id into v_mech from public.workflows where name = 'Joe''s Auto Repair';
  update public.workflows set report_config = '{
    "period": "week",
    "fields": [
      {"key": "invoice_amount",  "label": "Invoiced",  "unit": "$", "unit_position": "prefix", "item_agg": "last", "period_agg": "sum"},
      {"key": "estimate_amount", "label": "Estimated", "unit": "$", "unit_position": "prefix", "item_agg": "last", "period_agg": "sum"}
    ]}'::jsonb
  where id = v_mech;
  select jsonb_agg(r order by r.period_start) into v_rows
  from public.report_series(v_mech, '2026-10-01',
                            (now() at time zone 'America/Chicago')::date, 'America/Chicago') r;
  raise exception 'DRY RUN (rolled back): %', v_rows;
end;
$$;
```

`item_agg: last` is used because a job's amount is one value, not a running total across stages.
The mechanic never clears keys, so each job has exactly one segment per field anyway, and `sum`
would give the same answer.

What to expect:
- every `period_start` is a Monday;
- `item_count` matches the jobs created that week;
- the week of the job holding 300/500 shows `invoice_amount` 500 and `estimate_amount` 300;
- `field_counts` shows how many jobs had each amount;
- each row has four keys (no `field_shares`).

This is the only check of `period_agg: sum` on real data. It is not a commitment to a mechanic
config.

### Step 8. Build, commit, deploy, phone checks

1. `cd /home/mmcbride/micah/claude/workflow-app/web && dotnet build`.
2. **Only after Step 4a matches, Step 4b prints `PASS` and Step 7 prints the expected rows**, make
   one commit containing:
   - the two migrations;
   - both `scripts/*.sql` files;
   - the client changes;
   - both pages;
   - `timezone.js` and the `index.html` change.

   The message explains snapshot-on-clear, the per-stage dedupe, the two aggregation levels, and
   the A.4 rule (`item_requires`: a day without all three macros is left out of all four
   averages; calories is derived, never stored). Do not commit `plans/diet-workflow/test-plate.jpg`.
3. **With the user's go-ahead**, push to `main` (triggers `deploy-pages.yml`). Confirm the deploy
   succeeded.
4. On the phone:
   1. **Nutrition list.** A "Report" link appears. The mechanic and Feature Pipeline lists have none.
   2. **Report page.**
      - Exactly four cards, in order: Calories, Protein, Carbs, Fat. Each has a value and "avg
        per day".
      - No weight, fiber, sugar, days-included, split, trend or per-week list.
      - Step to the week of Nov 9: the four numbers match Step 4a.
      - If the page gets a 404/PGRST202 on `rpc/report_series`, apply the PostgREST-reload
        fallback in Section 4.
   3. **Stepper.** `›` is disabled on this week. `‹` steps back one week at a time. Stepping back
      to the week of Nov 2 (before the workflow's first item) shows "—" on all four cards. `›`
      returns.
   4. **Real forward-move path with a correction.** On today's item, enter Breakfast values,
      Complete Stage to Brunch, then enter Brunch values. Check today's contribution alone with a
      read-only one-day query. The range covers only today, so the "week" row holds just today's
      item:

      ```bash
      supabase db query --linked "select field_values from public.report_series(
        (select id from public.workflows where name = 'Nutrition Tracker'),
        (now() at time zone 'America/Chicago')::date, (now() at time zone 'America/Chicago')::date,
        'America/Chicago')"
      ```

      Log all three macros (Scan Plate does this). Under A.4, a day missing any of them returns
      `{}` here. Expect breakfast + brunch for each macro, and calories = 4p + 4c + 9f of those
      totals. Then
      move back to Breakfast, correct a value, and move forward again. Re-enter Brunch (the
      forward move clears it; that's existing behaviour). The query should now show corrected
      breakfast + brunch.
   5. (Removed: Weight card check.)
   6. **List label.** The 11-12 evening item reads `… 2026-11-12`.
5. If a phone check fails, fix it in a follow-up commit and re-check.

### Step 9. PROGRESS.md

Per `CLAUDE.md`, `PROGRESS.md` is updated at the next milestone the user asks for, not as an
automatic step. Points to carry into it:
- the weekly Nutrition report (four daily averages) is built, in dev only;
- add it to the not-yet-ported-to-prod list;
- the deferred write-side `move_stage` follow-up (D1 residual);
- the recorded answers to A.1–A.3, and that A.4 was resolved as (a), applied uniformly to all four
  numbers via `item_requires`, with calories derived and never stored.

## 4. Assumptions not verified

**`set local role authenticated`, `reset role` and `set_config('request.jwt.claims', …)` work inside a
`DO` block through `supabase db query --linked`.** Verified on the local stack as `postgres`, not
through the Management API. Check 6 (restoring the shipped config) and check 10 each add a
`reset role` / `set local role` round trip of the same kind.
- Detection: a permission or role error instead of `PASS`/`FAIL`.
- Fallback: the dashboard SQL editor, then Step 8 check 4.

**The CLI's role can update `items.created_at` (4b back-dating) and `workflows.report_config`
(check 1, the strip after it, check 6's restore and check 10).** It owns the tables on local; on dev the Management API runs as `postgres`,
which should too.
- Detection: a permission error right after `reset role`.
- Fallback: the dashboard SQL editor.

**PostgREST sees the new RPC right after `db push`.**
- Detection: 404/PGRST202 on the report page (Step 8 check 2). Step 4's SQL checks bypass
  PostgREST, so they can't detect this.
- Fallback: `supabase db query --linked "notify pgrst, 'reload schema'"`.

**The browser's `Intl` timezone is an IANA name Postgres recognizes.**
- Detection: `time zone "…" not recognized`.
- Fallback: retry once with `'UTC'` and show a "times shown in UTC" note.

**A CHECK calling a `private` function behaves on dev as on local**, including for any future
authenticated-role update of `workflows` (execute is granted to `authenticated` for that reason).
- Detection: Step 4b check 1 runs the real constraint on dev.


## 5. Risks and edge cases

- **The fourth redefinition of `move_stage`.** Mitigated by the literal body (Step 1), the Step 4
  diff, and 4b checks 8–9. Rollback: re-apply `20261113000000`'s body as a new migration. Old
  events keep their `cleared` data, which is harmless.
- **D1 residual** (backing out without editing). Matches the stage UI; deferred (A.2).
- **Today's partial day lowers the current week's averages** (A.1). The page no longer shows a day
  count, so this is not visible on the page.
- **A day with only some macros logged** (e.g. protein via chat). Under A.4 it's left out of all
  four averages, so even its logged protein appears nowhere on the page. The page shows no day
  count, so this exclusion isn't visible. The user chose this trade: in return, the four
  numbers always agree (avg calories = 4p + 4c + 9f of the averaged macros, exactly in the RPC's
  values, and up to display rounding on the cards). Scan Plate always writes all three macros, so
  these days only come from chat. No current dev item is one (re-checked 2026-11-15).
- **A genuinely zero macro must be logged as 0**, not left blank. A day with no fat logged at all
  is treated as "fat unknown" and dropped. Scan Plate writes explicit zeros. Through chat, "no fat
  today" only counts if the agent writes `fat_g: 0`. This is consistent with D9 and isn't
  addressed in this plan.
- **A week where no day has all three macros** shows "—" on all four cards.
- **Two items created on the same day** count as two "days" and are averaged as two. One item per
  day is the workflow's convention, not enforced.
- **Two items with identical `created_at`** under `period_agg: last`: the greater `items.id` wins
  (D9). Deterministic, not meaningful. Nutrition doesn't use `period_agg: last`.
- **Negative logged values** (e.g. a chat typo `-5`) are accepted by `jsonb_numeric` and by the
  write path. They lower averages. Documented limitation: very unlikely, visible in the stage UI,
  and per-field bounds would be a separate feature.
- **Values logged onto an older day's item** count toward that item's creation day.
- **Missing fields** show "—", not 0.
- **An unparseable live value** (e.g. the agent writes `"30g"`) makes that stage contribute
  nothing; the stage UI shows the same raw string.
- **Config edits are migrations**, and the CHECK rejects malformed shapes outright, so a bad config
  fails the push rather than rendering a broken page.
- **Mechanic revenue would bucket by creation week** (D5) if a mechanic config is ever committed.
- **Prod.** These migrations will go to prod with the 2026-11-12 batch.
  - The `move_stage` change is inert for prod's mechanic (no shared keys).
  - The `report_config` update matches by name, so it only applies if a "Nutrition Tracker"
    workflow exists there. Porting it is a separate, open decision.
- **Rollback.** Revert the web commit. The column is additive. A new migration undoes the rest:
  `alter table workflows drop column report_config; drop function public.report_series(uuid,date,date,text),
  private.jsonb_numeric(jsonb), private.report_fields_valid(jsonb),
  private.report_item_requires_valid(jsonb, jsonb);`. Drop the column first: the CHECK depends on
  both validators. Roll back `move_stage` as above.

## 6. Out of scope (deliberate)

- **Goals / targets of any kind** (removed at the user's request).
- **Any number on the Nutrition report beyond the four averages:**
  - macro % split;
  - weight, fiber or sugar;
  - days-included or per-card day counts;
  - trend charts and per-week lists.

  The engine could show more fields via config. Nutrition's config doesn't ask for them.
- **Chat / Q&A access to report numbers.** Discussed and explicitly set aside in favour of this
  static page. That means no chat scope, no agent tool and no preset questions (D8).
- Reports for any workflow other than Nutrition Tracker; committing a mechanic `report_config`.
- A day-by-day breakdown inside the weekly view (a `period: "day"` config would give one, later).
- Cross-workflow reports, custom queries, export, saved views, per-user configs.
- Derived fields beyond positive weighted sums (differences like profit, ratios,
  derived-of-derived), and partial-component derived values.
- Per-field opt-outs from `item_requires`, or more than one item set per report. One shared
  day-set is the point of A.4.
- Fiber-adjusted calories (fiber at ~2 kcal/g).
- Turnaround metrics and `date_anchor: "terminal"`.
- Backfilling the pre-snapshot test day; back-dating real items.
- Porting to prod.
- A range cap on `report_series` (round-2 S2, rejected: RLS already scopes it, like `search_items`).
- **The write-side `move_stage` change** for backward moves (A.2).

---

## 7. Prior architect review (round 4, carried forward)

The round-4 architect verdict was **`approved-with-changes`**. Round 5 was never separately
architect-reviewed; round 6 (which includes round 5's changes) was, and its adjudication is
Section 10. What still stands from the round-4 review:

- **Architectural fit.** Per-workflow behaviour is jsonb config on `workflows`, following the
  `stages.checklist` precedent, with one generic RPC and one generic page. There is no new
  `item_label` branch or field-name gate, and the 4/4/9 factors live in Nutrition's config row. It
  follows the codebase's conventions: a security-invoker RPC scoped by RLS like `search_items`,
  `private` helpers with explicit `revoke`/`grant`, and one self-contained rolled-back `DO` block
  per dev check. **Round 5 doesn't change any of this.** The narrowing is a config change plus
  deletions. **Round 6 doesn't either.** It adds one top-level config property, validated by the
  CHECK like the others and read generically by the RPC, with no field-name gate.
- **Grants.** `report_series` reads `workflows`, `items` and `item_events`. `authenticated`
  already has `select` on all three (`20261101000000_grant_authenticated_table_access.sql`), and
  the new column is covered by the existing table-level grant. The CHECK's `private` function has
  an explicit `execute` grant to `authenticated`.
- **Coupling to watch.** The `move_stage` snapshot (Step 1) makes `item_events.data` load-bearing
  for reporting, so any future change to `move_stage` must keep writing `cleared`. This is the
  fourth redefinition of `move_stage`. The literal body plus the Step 4 diff is the right control.
- **Complexity budget.** The RPC is now about 110 lines of CTEs: about 95 after round 5 removed the
  two share CTEs, plus round 6's `required`/`kept`. Each CTE maps to one named step of D1/D9/D10. The derived-field
  mechanism stays capped at positive weighted sums of base fields.
- **Adjudications still in force:**
  - the 27-case validator suite and its missing-`key` hardening (33 cases since round 6 added 6
    for `item_requires`);
  - `ItemLabelPlural` duplicated, not extracted;
  - negative values documented, not rejected;
  - option (a)'s engine-wide "every component required" precedent, now the shipped rule (D10).
- **Adjudications now moot:**
  - the A.4 answer gate and the "(a)/(b)/(c) must be named" wording (A.4 is resolved);
  - option (b)'s SQL;
  - the "asymmetric fourth option" (it was about the split);
  - the split-legend gram formula.

**History.**
- Round 3: goals removed; `item_agg`/`period_agg` (D9); calories and the split moved into
  config-driven RPC logic (D10).
- Round 4: A.4 added as a user decision; the `period_agg: last` tie-break added; CHECK test claims
  corrected.
- Architect pass: answer gate, recommendation (a), 27-case validator suite.
- Round 5: scope narrowed by the user (Section 8).
- Round 6: this draft. The A.4 filter now applies to all four numbers via `item_requires`, and
  calories is confirmed as never stored (Section 9).

Per-round feedback tables live in `round-3-draft.md` / `round-4-draft.md` and their review files.

## 8. Changes from round-4-final-plan.md (round 5: scope narrowed by the user)

1. **The report is four numbers.**
   - Nutrition's `report_config` is now `calories` (derived), `protein_g`, `carbs_g` and `fat_g`,
     all `period_agg: avg`, with the macros `item_agg: sum`.
   - `weight_lbs`, `fiber_g`, `sugar_g`, `show_count`, `count_label`, `hidden` and `split` are
     gone from it.
   - Protein, carbs and fat are now visible cards rather than hidden components.
2. **A.4 resolved as (a)** and removed from the open list.
   - Step 2 uses `round-4-final-plan.md`'s A.4 (a) `item_terms_all`/`item_terms` CTEs as the only
     behaviour.
   - The (b) and (c) variants, the "A.4 variants" block and the answer gate are deleted.
   - The migration comment states the rule and that the user chose it.
   - D10 records the three former options and why (a) was chosen.
3. **% split removed.**
   - `period_terms`/`period_shares` and the `field_shares` return column are deleted.
   - The split UI (bar, colours, legend, gram formula) and `ReportPeriodRow.Shares` are deleted.
   - D10 no longer argues for energy-weighted shares.
   - The `weights` map stays, because it's how calories is computed.
4. **Days-included count removed.** The count card, `show_count`/`count_label` and
   `ReportConfig.ShowCount`/`CountLabel` are gone. `item_count` stays in the RPC output (generic,
   undisplayed).
5. **Page reduced to four cards plus a week stepper** (stepper kept as a flagged judgment call,
   Section A).
   - Removed: trend SVG, trend-length chips, `AddPeriods`, the per-week list, the per-card
     "· n days" counts, and `ReportPeriodRow.ItemCount`/`Counts`.
   - Added: `PrevPeriod`, which the stepper needs and which `AddPeriods` used to cover.
   - The fetch range is now exactly the focused period.
6. **D3 schema trimmed** to the properties that are still used. None of the removed ones was
   validated by the CHECK, so the validator and its 27-case suite are byte-for-byte unchanged.
7. **D9's table** now covers only the macros and calories. `last` stays in the engine and is
   covered by the new 4b check 10.
8. **Step 4a** cross-check reduced to the four numbers plus a `complete_days` count that must match
   `field_counts.calories`.
9. **Step 4b.**
   - Fiber and sugar are gone from the test data.
   - Weight assertions are gone from checks 2–3.
   - Check 6 asserts the four A.4 (a) numbers (43.75 / 60 / 20 / calories 600 over 2 days) and
     exactly four `field_values` keys. (Superseded in round 6: protein is now
     45 over 2 days, the same day-set as the other three; see Section 9.)
   - Check 10 is new: it tests `item_agg: last` and `period_agg: last` with a throwaway config.
   - The snapshot assertion in check 2 still includes `weight_lbs`, because it tests Step 1, not
     the report.
10. **Step 7** dry run drops `show_count` and expects no `field_shares`.
11. **Step 8.**
    - Check 2 expects exactly four cards.
    - Check 3 is stepper-only.
    - Check 4 uses a one-day `report_series` query instead of the removed per-week list.
    - Check 5 (weight) is tombstoned.
12. **A.1** rationale updated: the Days-included card that made the partial-day effect visible is
    gone. The default and the options are unchanged.
13. **Removed from Section 4:** the Fluent green/marigold token assumption (no split colours).
    **Added to Section 4:** the A.4 interpretation assumption (removed again in round 6, once the
    user answered it).
14. **D8 / Section 6** record that the chat/Q&A alternative was explicitly set aside.
15. The optional "Days included" label question is removed.

## 9. Changes from round-5-draft.md (round 6: one aggregation rule)

This is a narrow fix. Nothing outside this list changed.

1. **The A.4 filter now covers all four numbers, using one day-set.** A day counts toward calories,
   protein, carbs and fat only if it has all three macros. Round 5 filtered only calories.
   - Generic mechanism: a new optional top-level config property `item_requires` (D3), set to
     `["protein_g", "carbs_g", "fat_g"]` in Nutrition's config. The rejected alternatives are in
     D10.
   - Step 2 adds the validator `private.report_item_requires_valid`, one CHECK conjunct, the
     `required`/`kept` CTEs, and an `item_vals` join to `kept`. `report_fields_valid` and
     `jsonb_numeric` are unchanged.
2. **Calories is derived, never stored.** This was already the design. It's now stated as a
   settled decision in Section A's "Decided" list, in D10 and in the migration comment.
3. **Section A.** The A.4 entry states that the filter is uniform. The "A.4 interpretation check"
   is now a short resolved pointer. A.1 gets a one-sentence note on how A.4 treats today's
   partial day.
4. **Step 4a.** The cross-check computes all four averages over the same complete days, and every
   `field_counts` entry must equal `complete_days`.
5. **Step 4b.**
   - Check 1 now has 33 cases (6 new for `item_requires`).
   - The SETUP guard checks `item_requires`.
   - `item_requires` is stripped for checks 2–5 and restored for check 6. Checks 2–4 are unchanged.
   - Check 5 asserts that Thu's string `"25"` parses.
   - Check 6's numbers change from protein 43.75 (n=4) to **45 (n=2)**, and every count is 2.
     Carbs 60, fat 20 and calories 600 are unchanged. Check 6 also asserts calories = 4p + 4c + 9f
     exactly, and that Mon alone returns `{}`.
   - Checks 7–10 are unchanged in substance.
6. **Section 4:** the "these averages means calories only" assumption is removed. The role
   round-trip and CLI-update assumptions now mention check 6's restore.
7. **Section 5:** the partial-day risk is rewritten (dropped from all four, silently), the
   "log zero as 0" edge case is added, and the no-complete-day week shows "—" on all four cards.
8. Small matching edits in Sections 0.3, 1, D9, Step 5's parser table (`item_requires` is ignored
   client-side), Step 8 (commit message, check 4.4 note), Step 9, Section 6 and Section 7.

## Feedback from round 5 (carried forward for history)

Round 5's input was the user's scope narrowing, relayed in the task brief. There was no reviewer
feedback that round.

| directive | outcome |
|---|---|
| Page shows exactly four averages (calories, protein, carbs, fat) | **Adopted.** Config, UI, Step 4a/4b/8 all reflect four numbers. |
| A.4 resolved as (a); apply `round-4-final-plan.md`'s (a) SQL as the only behaviour | **Adopted as written.** **Flagged:** the user's wording ("a day only counts toward *these averages*") could mean all four numbers exclude partial days, which `round-4-final-plan.md`'s (a) does not do. That reading is laid out (with its cost and its effect on the test numbers) in Section A's interpretation check and gated in Step 4.0. The draft doesn't silently switch to it, because the brief explicitly named the existing (a) SQL and its 4b assertions. |
| Drop weight/fiber/sugar/days-count from Nutrition config and display; keep RPC generic | **Adopted.** `item_count`, `field_counts`, `last` at both levels and multi-field support all stay. Weight remains only as 4b test data. |
| Remove the % split entirely (keep the Atwater weights) | **Adopted.** Shares SQL, return column, UI and rationale removed. The `weights > 0` constraint is kept with a restated reason, so the 27-case suite stays unchanged. |
| Section A has only A.1–A.3, unchanged, plus a note that A.4 is resolved | **Adopted, with one wording change to A.1.** A.1's default and options are unchanged, but its rationale cited the now-removed Days-included card. Leaving that unchanged would have been inaccurate, so the text says so. |
| Everything else carries forward unless it only supported a dropped feature | **Adopted.** Step 1, D1, D9's split, the validator and 27 cases, the migration conventions and the "ask again before implementing" gate are unchanged. `hidden` and `split` were removed because they only existed for the split. `unit_position` and `item_noun` stay because they're generic. |
| Additions beyond the brief (open to challenge) | 1. **Week stepper kept**, even though "nothing else" could exclude it. Without it, past weeks can't be seen. Cutting it is cheap. 2. **4b check 10** added so that `last` (kept in the engine, no longer used by Nutrition) stays tested. This also gives `period_agg: last` its first test. Cutting it removes about 15 lines. 3. **`ReportPeriodRow` trimmed** to `Values` only. |

## Feedback from this round

This round's input was the user's answer to round 5's one open gate, relayed in the task brief.
There was no reviewer or sanity-check feedback this round.

| directive | outcome |
|---|---|
| Filter all four numbers with the same day-set: a day counts only if it has protein_g, carbs_g and fat_g | **Adopted.** It's built as the `item_requires` config property, the generic mechanism round 5 sketched. It's not an implicit side effect of `weights` and not a hardcoded key list (D10 gives the reasons). The RPC drops failing items from every field before period aggregation. |
| Confirm calories is purely derived, never stored, as a settled decision | **Adopted.** It was already the design. It's now stated explicitly in Section A, D10 and the migration comment. |
| Update Step 4a/4b assertions; calories = 4p + 4c + 9f must hold exactly in the fixture | **Adopted.** Check 6 is now 45/60/20/600, all over n=2, and 4·45 + 4·60 + 9·20 = 600. It's asserted directly. Step 4a's cross-check uses one complete-day set. |
| Remove the gate from Section A; note that A.4's filter is uniform | **Adopted.** The interpretation check is reduced to a short resolved pointer (kept in place, following the numbering convention). The Section 4 assumption and the Step 4.0 gate are removed. |
| Leave everything else unchanged | **Adopted, with three necessary knock-on changes, open to challenge.** (1) The validator suite grows from 27 to 33, because a new config property the CHECK doesn't validate would break D3's "the CHECK validates everything the RPC relies on". (2) The 4b strip/restore of `item_requires` around checks 2–4. Without it, Mon (protein only) would be dropped, and checks 2–4 (which test D1, not A.4) would fail. Changing Mon's data instead was rejected (see Step 4b). (3) A new "log a zero macro as 0" edge case in Section 5, which matters more now that a missing macro hides a whole day. If the reviewer prefers the implicit-from-`weights` rule to avoid (1), D10 lists it as the cheaper rejected alternative. |

## 10. Architect review (round 6, final)

**Verdict: `approved-with-changes`.** The design is sound and fits the codebase; the changes
below are wording, one rollback omission, one test-script comment, and one go-ahead note. None
changes what gets built, the SQL behaviour, or any test assertion. No further planning round is
needed. Implementation still waits for the three conditions at the top of this file, including
asking the user again right before starting.

**Section A check.** A.1–A.3 remain the only open items. Nothing new was added: the uniform A.4
filter and "calories never stored" were settled by the user in round 6, and the visibility
consequence below is a restatement at go-ahead time, not a new question.

### Adjudication of round-6 findings

| # | source | finding | ruling | action |
|---|---|---|---|---|
| R1 | review notes | Numbering note lumps A.4 / the interpretation check in with one-line tombstones | **Valid** | Numbering note rewritten: tombstones are D4, Step 3, Step 8 check 4.5; A.4 and the interpretation check are kept as resolved explanations. Section 9 item 3's "one-line pointer" wording corrected to match. |
| R2 | review notes | 4b SETUP guard compares `item_requires` with order-sensitive jsonb equality | **Valid, comment only** | Comment added above the guard. A set-equality rewrite would need NULL handling and isn't worth it for a guard whose literal sits next to the config it checks. |
| S1 | sanity check | `item_requires` is more machinery than "require every base field" | **Judgment call: original stands** | See the new rejected-alternative bullet in D10. The implicit rule can't be engine-wide (it changes the mechanic dry run and check 10), so it would need its own opt-in flag anyway, and a flag couples the day-set to the displayed fields. The explicit list is about 25 lines of validator and 6 test cases, already written and partially run. |
| S2 | sanity check | Uniform filter + no day count = silent exclusion; 2 of 6 fixture days count | **Valid as a communication point, not a plan change** | The user chose both halves explicitly. Not reopened as a Section A item. Added a "restate at the implementation re-ask" note in Section A with the one-sentence consequence and the cheap client-only fix if the user wants visibility back. |
| S3 | sanity check | D10's every-component rule and `item_requires` are redundant for Nutrition | **Valid, no change** | Already documented (Step 2 notes, D10). The engine-wide rule is still needed for any derived field in a config without `item_requires`; the two can't disagree, because `item_requires` is a strictly stronger gate whenever it lists all components. |

### Architect's own findings

| # | finding | action |
|---|---|---|
| A1 | Section 5's rollback `drop function` list omitted `private.report_item_requires_valid(jsonb, jsonb)` (added in round 6). | Added, with a note to drop the column first, since the CHECK depends on both validators. |
| A2 | The draft referred to the round-4 plan as `final-plan.md`. Overwriting that path with this plan would have made those references point at this file and destroyed the only copy (the directory is untracked). | The round-4 plan was copied, unchanged, to `round-4-final-plan.md`, and every reference was renamed. |
| A3 | Section 7 still said round 6 had not been architect-reviewed. | Updated to point here. |

### Architectural fit

- **Fits the codebase.** Per-workflow behaviour stays in jsonb config on `workflows`, following
  the `stages.checklist` precedent. There's one security-invoker RPC scoped by RLS like
  `search_items`, `private` helpers with explicit `revoke`/`grant`, and one self-contained,
  rolled-back `DO` block per dev check. `item_requires` is read generically with no field-name
  gate and is validated by the CHECK like every other RPC-relevant property, so D3's invariant
  ("the CHECK validates everything the RPC relies on") still holds.
- **Coupling to watch (unchanged).** `item_events.data.cleared` becomes load-bearing for
  reporting, so any future `move_stage` rewrite must keep writing it. The literal body plus the
  Step 4.1 diff is the right control.
- **Complexity budget.** The engine is more general than its one consumer needs: `last` at both
  levels, `day`/`month` periods, derived fields and `item_requires`. That generality was
  adjudicated in round 4 and kept deliberately. It is bounded (positive weighted sums only, one
  item set per report) and every piece is tested in 4b. It isn't growing further in this plan,
  and Section 6 lists the extensions that would need a new plan.
- **Precedent for future configs.** Because `item_requires` is opt-in, a future workflow that
  adds a derived field without it gets per-field denominators again, so its numbers won't
  necessarily satisfy the derived identity. That's the right default for a generic engine, and
  D10 says so.

### Most worth flagging to the user before implementation

1. The combined effect of the user's two choices: a day missing any macro disappears from all
   four cards, and the page never shows how many days an average covers.
2. The SQL added in rounds 5–6 has only been partially run locally. Step 4.0's full local re-run
   of both migrations and the 4b script (expecting `PASS` with "33 bad configs rejected") is
   mandatory before the `db push` go-ahead is requested.
