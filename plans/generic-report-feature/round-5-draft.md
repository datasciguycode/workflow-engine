# Generic per-workflow Report: round-5 draft (Nutrition weekly report: four daily averages)

**Status: PLANNING ONLY. Do not implement.** This draft supersedes `final-plan.md` (the
architect-approved plan from round 4) and stands on its own. The user narrowed the scope after
seeing that plan, in conversation; the only written record of that conversation is the round-5
task brief, and this file. The architecture is unchanged. What changed is what Nutrition
Tracker's report shows, plus everything that existed only to support the dropped parts. Section 8
lists every cut.

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
Step 3, A.4 (now resolved) and Step 8 check 4.5.

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
   macros (Scan Plate writes all three), so the A.4 rule below doesn't exclude it.
   - **Default: include it.** It's the simplest option.
   - Alternative: for the *current* week only, the page passes `p_to = yesterday` instead of
     `today`. That's a one-line client change (Step 6c) and needs no SQL change. Downside: on a
     Monday the current week shows as empty (all four "—").
   - Past weeks are unaffected either way.
   - *What changed this round:* the default was originally justified partly by "the Days included
     card makes the effect visible". That card is gone, so the page no longer shows that today is
     a partial day. The default is unchanged, but it's now a closer call than it was. The week
     stepper (Step 6c) still shows last week's finished numbers one tap away.
   - **Answer:** _(pending)_
2. **Accept the D1 residual for now?** If you go back to an earlier stage and then move forward
   again *without editing*, the values carried over from the later stage replace the earlier
   stage's original values. The stage UI already loses this data in the same way today. The full
   fix is a write-side `move_stage` change: backward moves would snapshot and restore values. That
   changes what users see when they go back a stage, so it is **deferred** to a separate
   follow-up.
   - **Default: accept it, and defer the fix.**
   - **Answer:** _(pending)_
3. **Commit and push sequencing (Step 8).**
   - **Default:** one commit for all the work, pushed to `main` once Steps 4 and 7 pass. The phone
     checks then run against the deployed Pages site, and any fixes go in follow-up commits.
   - The alternative is to test locally before any push. That needs the phone to reach a local
     `dotnet run`, and the Google OAuth redirect to allow that origin. Neither is set up today.
   - **Answer:** _(pending)_
4. **(Resolved, not open: partial-macro days.)** The user chose **option (a)**: a day counts
   toward the calories average only if it has all three of protein_g, carbs_g and fat_g. This
   applies D9's rule ("a field that was never logged is left out, not counted as 0") to calories:
   a day missing a macro has *unknown* calories, not calories computed as if that macro were 0.
   The SQL is in Step 2, and D10 describes the behaviour.

### A.4 interpretation check (not a new decision; for the reviewer/orchestrator)

The user's rule, as relayed, reads: "a day only counts toward **these averages** if it has all three
macros". "These averages" can be read as **all four numbers**. The brief also says to apply
`final-plan.md`'s option (a) exactly as specified, and that version only filters **calories**. A
partial day (e.g. protein only) still counts toward the protein average. This draft follows the
explicit instruction, **(a) as specified**. The two readings give different numbers whenever a week
contains a partial day:

| reading | protein / carbs / fat avg (4b test week) | calories | do the four numbers agree? |
|---|---|---|---|
| (a) as specified (this draft) | 43.75 (4 days) / 60 (2) / 20 (2) | 600 (2 days) | No. 4·43.75 + 4·60 + 9·20 = 595 ≠ 600 |
| all four numbers use complete days only | 45 / 60 / 20 (2 days each) | 600 | Yes. 4·45 + 4·60 + 9·20 = 600 |

With the split gone, the four numbers sit side by side, so the mismatch is easier to notice than
before. It only shows up in weeks with a partial day, which only chat-only logging creates (A.4
background, Section 5).

If the user meant the second reading, the generic way to build it is a top-level config property
such as `"item_requires": ["protein_g", "carbs_g", "fat_g"]`. Items missing any listed base field
would be dropped from **every** field for that report. That would be about 10 lines of SQL (filter
`its` against `item_base`), a validator branch with 2–3 new check-1 cases (each entry must name a
base field), and 4b check 6 changing to protein 45 with every count 2. It is **not** in this draft.
Confirm the reading with the user before implementation. It's a one-sentence question.

**Decided in this plan; no input needed unless you disagree:**
- Calories is computed **in the RPC**, from config (D10). It is not hardcoded in SQL or C#.
- Weekly calories = the **average of each day's calories** (each complete day's 4p + 4c + 9f)
  (D10).
- A day where a field was never logged is **left out of that field's average**, not counted as 0
  (D9).
- Negative logged values (for example a typo'd `-5` from a chat correction) are **not** rejected.
  This is a documented limitation (Section 5), not a code change.
- **Page scope (a judgment call; flag it if it's wrong).** The page has four value cards and a
  `‹ This week ›` stepper for moving between weeks. The stepper isn't one of the four numbers, but
  without it last week's finished averages can't be seen at all, and on a Monday morning the page
  would show an almost empty week. The trend charts, trend-length chips, per-week list and per-card
  day counts are gone. Dropping the stepper too would delete about 15 lines from Step 6c and its
  phone check (Step 8 check 4.3).

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
  aggregation levels, derived-field weights) is read from that config. In particular, the Atwater
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
   each field's **two independent aggregation settings** (`item_agg`, `period_agg`), and optional
   **derived fields** (a weighted sum of other fields, e.g. calories). `null` means no report.
3. **Read path.** One `report_series` RPC (security invoker) returns per-period values and
   per-field counts, in a caller-supplied timezone. Snapshots are deduped per
   (item, departing stage, field).
4. **UI.** A generic page `/workflow/{WorkflowId}/report` (`WorkflowReport.razor`), linked from
   `WorkflowDetail`'s list view when `report_config` is set. It shows one value card per configured
   field for the focused period, plus a period stepper.
5. **Content.** Only Nutrition Tracker gets a `report_config`: weekly, four fields. Calories is
   derived (4p + 4c + 9f per complete day, averaged). Protein, carbs and fat are each summed within
   a day and averaged across the week. The mechanic gets a rolled-back dry run only.

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

**Removed this round (all UI-only, never validated by the CHECK):** `show_count` and `count_label`
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
- unique keys.

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
  - So `avg` means "average over the days that have a value".
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

**Computation, in `report_series`:**
1. **Per item:** `calories = Σ weight_k × item_value_k` over the components, **only if the item has
   a non-null value for every component**. Otherwise the item has no calories value and is left
   out of the calories average. An item missing fat has no calories, not 4p + 4c.
2. **Per period:** `period_agg` (`avg`) over the items' calories, which gives **average daily
   calories**.

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

*Effect on base fields:* a partial day still counts toward each macro's own average. See the A.4
interpretation check in Section A. If the user meant all four numbers to exclude partial days,
this is the part that changes.

**Why average the per-day calories, rather than derive calories from the averaged grams.**
- Daily calories is a per-day quantity, and "average daily calories" is literally the mean of the
  daily figures.
- Deriving from averaged grams (`4·avg(p) + 4·avg(c) + 9·avg(f)`) gives the same answer when every
  day has all three macros. When days differ, it mixes denominators.
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
justified for exactly that kind. Keeping it also leaves the 27-case validator suite unchanged.
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

Compared with `final-plan.md`:
- The validator (`report_fields_valid`), the CHECK and `jsonb_numeric` are **byte-for-byte
  unchanged**.
- `report_series` changes in three ways:
  - the A.4 (a) `item_terms_all`/`item_terms` CTEs replace the old `item_terms`;
  - `period_terms` and `period_shares` are deleted;
  - `field_shares` is dropped from the return type and the final `select`.
- The Nutrition config is down to four fields.
- The header comments are updated to match.

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
-- Calories = 4p + 4c + 9f lives in config, not code.
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

alter table public.workflows
  add column report_config jsonb
  constraint workflows_report_config_shape check (
    report_config is null or (
      jsonb_typeof(report_config) = 'object'
      and coalesce(report_config ->> 'period', '') in ('day', 'week', 'month')
      and private.report_fields_valid(report_config -> 'fields')
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
-- for items with every component); then every field's item values are combined with its
-- period_agg.
-- field_counts = items with a non-null value per field (the denominator of an avg).
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
  item_vals as (
    select item_id, key, period_agg, v from item_base
    union all
    select item_id, key, period_agg, sum(e) from item_terms group by item_id, key, period_agg
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
-- macros sum across meal stages. Across the week: each averages over the days that have a value;
-- calories only over days with all three macros. fiber_g/sugar_g/weight_lbs are still logged on
-- every stage but are deliberately not reported.
update public.workflows
set report_config = '{
  "period": "week",
  "item_noun": "day",
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
    - 4b check 10.
  - Step 4.0 makes the local re-run mandatory.
- **A.4 (a) mechanics.** An item is excluded from a derived field if any component has no
  `item_base` row (the component was never logged at any stage) or has a null value (logged but
  unparseable). Both cases make `item_terms_all`'s count for that item fall short of the number of
  weights. Because `jsonb_each` over an object yields each weight key once, the `derived_terms`
  count is exactly the number of components.
  - The correlated subqueries run once per row of `item_terms_all`. That's at most 3 rows per item
    for Nutrition, which is negligible at these volumes.
  - An equivalent `group by … having count(*) = …` form was considered. The CTE above was kept
    because it's the text the user approved as option (a) in `final-plan.md`.
- **Validator coverage.** Step 4b check 1 holds **27 bad configs** (unchanged from `final-plan.md`).
  Together they cover every rejection branch of `report_fields_valid` and of the top-level CHECK.
  Each one must be rejected as `check_violation`, never as another error. The architect review
  evaluated the CHECK expression against all 27 on the local stack (rolled back). All came out
  strictly `false`, never NULL, and a Nutrition-shaped config came out `true`.
  - That run found one fragile branch. For a field with **no `key`**,
    `jsonb_typeof(f -> 'key') <> 'string'` is NULL, so the `case` fell through. The config was
    rejected only by accident: `count(distinct …)` ignores NULLs, so the uniqueness check failed.
    The `coalesce(…, '')` above makes that branch reject the field directly. Check 1's two
    missing-key cases cover it.
  - None of the 27 configs uses `split`, `hidden` or `show_count`, so removing those properties
    doesn't touch the suite.
- **Accepting a valid config** is covered in two places. The shipped four-field Nutrition config
  must apply, and the 4b SETUP guard fails if `report_config` is still null. Check 10 also
  applies a second valid config (with `last` at both levels).
- **`jsonb_numeric` edge cases.**
  - A non-numeric live value still counts as that stage's latest segment, with value null. That
    stage contributes nothing, and the report doesn't fall back to an older snapshot. If every
    stage that day is non-numeric for a macro, the day has no value for it, so under A.4 (a) it
    has no calories either.
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
1. Section A has a recorded answer for A.1–A.3, and the A.4 interpretation check has been settled
   with the user. If the user meant "all four numbers use complete days only", this plan needs a
   revision first (see Section A).
2. Re-run both files on the local stack the same way as before (Section 0.2): apply the missing
   intermediate migrations plus Step 1 and Step 2 inside `begin … rollback`, then run the 4b block.
   It must print `PASS` with "27 bad configs rejected".
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
    and date_trunc('week', created_at at time zone 'America/Chicago')::date = '2026-11-09')
select count(*) n, avg(p) protein, avg(c) carbs, avg(f) fat,
       avg(case when p is not null and c is not null and f is not null then 4*p + 4*c + 9*f end) calories,
       count(*) filter (where p is not null and c is not null and f is not null) complete_days
from i"
```

All four numbers must match the RPC row, and `complete_days` must equal
`field_counts.calories` (4 today). If they differ, first check whether any of those items has a
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
  if (select report_config from public.workflows where id = v_wf) is null then
    raise exception 'SETUP: Nutrition Tracker has no report_config (Step 2 content update did not match)';
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
    '{"period": "week", "fields": null}'
  ] loop
    begin
      update public.workflows set report_config = c::jsonb where id = v_wf;
      raise exception 'FAIL check: accepted %', c;
    exception when check_violation then v_rej := v_rej + 1; end;
  end loop;
  if v_rej <> 27 then raise exception 'FAIL check count: % of 27 rejected', v_rej; end if;

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

  ---------------------------------------------------------------- 6. the four weekly numbers (A.4 (a): calories only over complete days)
  select item_count, field_values, field_counts into v_n, v_fv, v_fc
  from public.report_series(v_wf, v_wk, v_wk + 6, v_tz);
  if v_n is distinct from 6
     or (select count(*) from jsonb_object_keys(v_fv)) is distinct from 4
     or round((v_fv ->> 'protein_g')::numeric, 2) is distinct from 43.75
     or (v_fv ->> 'carbs_g')::numeric   is distinct from 60
     or (v_fv ->> 'fat_g')::numeric     is distinct from 20
     or (v_fv ->> 'calories')::numeric  is distinct from 600
     or (v_fc ->> 'calories')::int  is distinct from 2
     or (v_fc ->> 'protein_g')::int is distinct from 4
     or (v_fc ->> 'carbs_g')::int   is distinct from 2 then
    raise exception 'FAIL week: count % values % counts % (want 4 keys; protein 43.75/4, carbs 60/2, fat 20, calories 600/2 [385/4 = partial days counted])',
      v_n, v_fv, v_fc;
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

  raise exception 'PASS (all rolled back): jsonb_numeric ok, % bad configs rejected, snapshot ok, within-day 50/55/60, week four numbers ok (calories 600 over 2 complete days), tz ok, mechanic data null, enforce: %, generic last ok',
    v_rej, v_fp_note;
end;
$$;
```

How check 6's expected numbers come about (the test week, Chicago):

| day | protein | carbs | fat | complete? | calories |
|---|---|---|---|---|---|
| Mon (d_a) | 40 + 20 = 60 (breakfast + brunch snapshots, after dedupe) | — | — | no | — |
| Tue (d_b) | 40 | 40 | 20 | yes | 500 |
| Wed (d_c) | — | — | — | no | — |
| Thu (d_d) | 25 (string `"25"`) | — | — | no | — |
| Fri (d_e) | 50 | 80 | 20 | yes | 700 |
| Sun 21:00 (d_f) | — | — | — | no | — |
| **week** | avg 43.75 (n=4) | 60 (n=2) | 20 (n=2) | | **600** (n=2) |

- `item_count` is 6, including the two empty days. It's returned but not displayed.
- `field_values` has exactly four keys. `weight_lbs` is in the test data but not in Nutrition's
  config, so it must not appear.
- The old behaviour (option (c), partial days counted with the macros they have) would give 385
  over 4 days: Mon 240 and Thu 100 would be included. The FAIL message names that value.
- Deriving calories from the averaged grams would give 4·43.75 + 4·60 + 9·20 = 595, not 600. That
  number is also why the A.4 interpretation check in Section A matters.

How check 10's expected numbers come about:
- Mon's weight is 180 (breakfast snapshot) then 181 (live at lunch). `last` gives 181, where `sum`
  would give 361 and `avg` 180.5. Tue is 178. `period_agg: avg` over the two gives 179.5, with
  n = 2.
- `protein_g` with `period_agg: last` takes the latest-created item that has a value. Sun (d_f)
  has none, so it's Fri: 50. This is the first test of `period_agg: last` anywhere in the plan.

Notes:
- Each `FAIL` names its check and prints actual values.
- Each nested `exception when check_violation` rolls back only its own subtransaction. `FAIL`
  raises are P0001, which those handlers don't catch, so they propagate.
- Check 9's handler re-raises anything that isn't a `forward skip…` error.
- The CHECK probes (check 1) and check 10's config swap run as the CLI's role, so they don't depend
  on `workflows_update` RLS. Check 10's config passes the CHECK. Every key is a non-empty string,
  each field has valid `item_agg`/`period_agg`, and there are no weights.
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
| any other property (e.g. a stale `split`, `hidden`, `show_count`) | ignored |

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

(`AddPeriods` from `final-plan.md` is gone. It only computed the start of the multi-period trend
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
   the A.4 (a) rule for calories. Do not commit `plans/diet-workflow/test-plate.jpg`.
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

      Expect breakfast + brunch for each macro, and calories = 4p + 4c + 9f of those totals. Then
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
- the recorded answers to A.1–A.3, and that A.4 was resolved as (a).

## 4. Assumptions not verified

**`set local role authenticated`, `reset role` and `set_config('request.jwt.claims', …)` work inside a
`DO` block through `supabase db query --linked`.** Verified on the local stack as `postgres`, not
through the Management API. Check 10 adds a second `reset role` / `set local role` round trip, of
the same kind.
- Detection: a permission or role error instead of `PASS`/`FAIL`.
- Fallback: the dashboard SQL editor, then Step 8 check 4.

**The CLI's role can update `items.created_at` (4b back-dating) and `workflows.report_config`
(checks 1 and 10).** It owns the tables on local; on dev the Management API runs as `postgres`,
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

**The user's "these averages" means calories only, as in `final-plan.md`'s option (a).** Not
verified; see the A.4 interpretation check in Section A. Step 4.0 item 1 gates on it.

## 5. Risks and edge cases

- **The fourth redefinition of `move_stage`.** Mitigated by the literal body (Step 1), the Step 4
  diff, and 4b checks 8–9. Rollback: re-apply `20261113000000`'s body as a new migration. Old
  events keep their `cleared` data, which is harmless.
- **D1 residual** (backing out without editing). Matches the stage UI; deferred (A.2).
- **Today's partial day lowers the current week's averages** (A.1). The page no longer shows a day
  count, so this is not visible on the page.
- **A day with only some macros logged** (e.g. protein via chat). Under A.4 (a), it's left out of
  calories but still counts toward the macros it has. In such a week the displayed calories won't
  equal 4p + 4c + 9f of the displayed macro averages (4b test week: 600 vs 595). Scan Plate
  always writes all three macros, so these days only come from chat. No current dev item is one
  (re-checked 2026-11-15).
- **A week where no day has all three macros** shows "—" for Calories but numbers for the macros
  that were logged.
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
  private.jsonb_numeric(jsonb), private.report_fields_valid(jsonb);`. Roll back `move_stage` as
  above.

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
- Fiber-adjusted calories (fiber at ~2 kcal/g).
- Turnaround metrics and `date_anchor: "terminal"`.
- Backfilling the pre-snapshot test day; back-dating real items.
- Porting to prod.
- A range cap on `report_series` (round-2 S2, rejected: RLS already scopes it, like `search_items`).
- **The write-side `move_stage` change** for backward moves (A.2).

---

## 7. Prior architect review (round 4, carried forward)

The round-4 architect verdict was **`approved-with-changes`**. This round-5 draft has **not** been
through architect review. What still stands from that review:

- **Architectural fit.** Per-workflow behaviour is jsonb config on `workflows`, following the
  `stages.checklist` precedent, with one generic RPC and one generic page. There is no new
  `item_label` branch or field-name gate, and the 4/4/9 factors live in Nutrition's config row. It
  follows the codebase's conventions: a security-invoker RPC scoped by RLS like `search_items`,
  `private` helpers with explicit `revoke`/`grant`, and one self-contained rolled-back `DO` block
  per dev check. **Round 5 doesn't change any of this.** The narrowing is a config change plus
  deletions.
- **Grants.** `report_series` reads `workflows`, `items` and `item_events`. `authenticated`
  already has `select` on all three (`20261101000000_grant_authenticated_table_access.sql`), and
  the new column is covered by the existing table-level grant. The CHECK's `private` function has
  an explicit `execute` grant to `authenticated`.
- **Coupling to watch.** The `move_stage` snapshot (Step 1) makes `item_events.data` load-bearing
  for reporting, so any future change to `move_stage` must keep writing `cleared`. This is the
  fourth redefinition of `move_stage`. The literal body plus the Step 4 diff is the right control.
- **Complexity budget.** The RPC is now about 95 lines of CTEs, down from about 110 now that the
  two share CTEs are gone. Each CTE maps to one named step of D1/D9/D10. The derived-field
  mechanism stays capped at positive weighted sums of base fields.
- **Adjudications still in force:**
  - the 27-case validator suite and its missing-`key` hardening;
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
- Round 5: this draft (scope narrowed by the user; see Section 8).

Per-round feedback tables live in `round-3-draft.md` / `round-4-draft.md` and their review files.

## 8. Changes from final-plan.md (round 5: scope narrowed by the user)

1. **The report is four numbers.**
   - Nutrition's `report_config` is now `calories` (derived), `protein_g`, `carbs_g` and `fat_g`,
     all `period_agg: avg`, with the macros `item_agg: sum`.
   - `weight_lbs`, `fiber_g`, `sugar_g`, `show_count`, `count_label`, `hidden` and `split` are
     gone from it.
   - Protein, carbs and fat are now visible cards rather than hidden components.
2. **A.4 resolved as (a)** and removed from the open list.
   - Step 2 uses `final-plan.md`'s A.4 (a) `item_terms_all`/`item_terms` CTEs as the only
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
     exactly four `field_values` keys.
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
    **Added to Section 4:** the A.4 interpretation assumption.
14. **D8 / Section 6** record that the chat/Q&A alternative was explicitly set aside.
15. The optional "Days included" label question is removed.

## Feedback from this round

This round's input was the user's scope narrowing, relayed in the task brief. There was no
reviewer feedback this round.

| directive | outcome |
|---|---|
| Page shows exactly four averages (calories, protein, carbs, fat) | **Adopted.** Config, UI, Step 4a/4b/8 all reflect four numbers. |
| A.4 resolved as (a); apply `final-plan.md`'s (a) SQL as the only behaviour | **Adopted as written.** **Flagged:** the user's wording ("a day only counts toward *these averages*") could mean all four numbers exclude partial days, which `final-plan.md`'s (a) does not do. That reading is laid out (with its cost and its effect on the test numbers) in Section A's interpretation check and gated in Step 4.0. The draft doesn't silently switch to it, because the brief explicitly named the existing (a) SQL and its 4b assertions. |
| Drop weight/fiber/sugar/days-count from Nutrition config and display; keep RPC generic | **Adopted.** `item_count`, `field_counts`, `last` at both levels and multi-field support all stay. Weight remains only as 4b test data. |
| Remove the % split entirely (keep the Atwater weights) | **Adopted.** Shares SQL, return column, UI and rationale removed. The `weights > 0` constraint is kept with a restated reason, so the 27-case suite stays unchanged. |
| Section A has only A.1–A.3, unchanged, plus a note that A.4 is resolved | **Adopted, with one wording change to A.1.** A.1's default and options are unchanged, but its rationale cited the now-removed Days-included card. Leaving that unchanged would have been inaccurate, so the text says so. |
| Everything else carries forward unless it only supported a dropped feature | **Adopted.** Step 1, D1, D9's split, the validator and 27 cases, the migration conventions and the "ask again before implementing" gate are unchanged. `hidden` and `split` were removed because they only existed for the split. `unit_position` and `item_noun` stay because they're generic. |
| Additions beyond the brief (open to challenge) | 1. **Week stepper kept**, even though "nothing else" could exclude it. Without it, past weeks can't be seen. Cutting it is cheap. 2. **4b check 10** added so that `last` (kept in the engine, no longer used by Nutrition) stays tested. This also gives `period_agg: last` its first test. Cutting it removes about 15 lines. 3. **`ReportPeriodRow` trimmed** to `Values` only. |
