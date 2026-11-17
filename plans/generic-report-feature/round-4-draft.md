# Generic per-workflow Report: round-4 draft (Nutrition weekly report, no goals)

**Status: PLANNING ONLY. Do not implement.** This draft supersedes `final-plan.md` and
`round-3-draft.md`. The user changed the scope after seeing `final-plan.md`; round 3 wrote that new
scope down, and this round is a targeted revision of round 3 (one new user decision, A.4, plus three
precision fixes; see "Changes from `round-3-draft.md`" at the end). This file is self-contained. No code, migration, `supabase db push`, commit or push happens until the user has
reviewed and agreed to this plan, **and the user wants to be asked again before implementation
starts, even after they approve it.**

Dev only: repo `/home/mmcbride/micah/claude/workflow-app`, Supabase project `workflow-engine-test`
(ref `utwyvtbzesswpoihmlic`, linked). Nothing here touches `workflow-app-prod`.

**Numbering note.** Decision IDs (D1–D8) and Step numbers (1–9) keep the meaning they had in
`final-plan.md` so reviewers can compare the two. Removed items stay as one-line tombstones
(D4, Step 3). New decisions are D9 and D10. Section A items A.1–A.3 keep their round-3 meaning;
A.4 is new in round 4.

---

## A. Decisions the user needs to make before implementation

1. **Does the current week's average include today's unfinished day?** Today's item usually holds
   only breakfast (or nothing) until evening. Included, it drags the current week's calorie/fiber/
   sugar averages down until the day is done, and "Days included" counts it.
   - **Default in this plan: include it.** Simplest, and "Days included" makes the effect visible.
   - Alternative: for the *current* week only, the page passes `p_to = yesterday` instead of
     `today`. That's a one-line client change (Step 6c), no SQL change. Downside: on a Monday the
     current week shows as empty.
   - Past weeks are unaffected either way.
2. **Accept the D1 residual for now?** (Carried over unchanged.) If you back out to an earlier stage
   and move forward again *without editing*, the values carried over from the later stage replace
   the earlier stage's original values. The stage UI loses the same data the same way today. The
   full fix is a write-side `move_stage` change (backward moves snapshot and restore values); it
   changes what users see when they go back a stage, so it is **deferred** as a separate follow-up.
3. **Commit and push sequencing (Step 8).** (Carried over unchanged.) Recommended: one commit for
   all the work, pushed to `main` once Steps 4 and 7 pass; phone checks then run against the
   deployed Pages site; fixes go in follow-up commits. The alternative (test locally before any
   push) needs the phone to reach a local `dotnet run` and the Google OAuth redirect to allow that
   origin; neither is set up today.
4. **How should days with only some of protein/carbs/fat count toward Calories and the % split?**
   (New in round 4.) **This plan does not pick; implementation waits on your choice.**

   *The problem.* D10 computes a day's calories from whichever of protein/carbs/fat that day has
   (a day with protein only gets 4 × protein), then averages those daily figures. A day that is
   missing a macro is treated as if that macro was 0, not as "unknown". Such a day pulls the
   weekly Calories average down, and pulls the split toward whichever macro it does have. Nothing
   on the Calories card shows that this happened. Using Step 4b's test week (Tue and Fri fully
   logged; Mon and Thu protein only):

   | | days counted | avg calories | protein / carbs / fat split |
   |---|---|---|---|
   | partial days included (current D10 behaviour) | 4 | 385 kcal | 45% / 31% / 23% |
   | only fully logged days | 2 | 600 kcal | 30% / 40% / 30% |

   *How often this happens.* Scan Plate always writes all three macros, so a partial-macro day comes
   from a chat entry or correction that sets only some of them. Checked read-only on dev on
   2026-11-15: **all four current Nutrition items have all three macros**, including the ones still
   at an early stage. A day that has only reached Breakfast is a different kind of incompleteness:
   all three macros are present, but later meals haven't been logged yet. That's A.1 (today's
   unfinished day), and none of the options below changes it. So this decision is about how the
   report treats chat-entered partial days if they occur, not about data already in dev.

   *Options, with what each costs to implement:*
   - **(a) Count a day toward Calories and the split only if it has all three macros.** Partial
     days are left out of both numbers entirely. They still count toward each macro's own average
     and toward Weight/Fiber/Sugar if those were logged. Every calorie figure is then based on
     complete days, and the 385-vs-595 difference in D10 can't arise.
     Cost:
     - **RPC (Step 2):** a derived field's per-item value and its share terms use only items that
       have a value for *every* component in `weights`. Make this the rule for all derived fields,
       with no config property: a weighted sum missing some of its terms is unreliable for any
       workflow, and an opt-in flag would need its own default. Concretely, replace `item_terms`
       with:
       ```sql
       item_terms_all as (
         select ib.item_id, d.key, d.period_agg, d.comp, d.weight * ib.v as e
         from derived_terms d
         join item_base ib on ib.key = d.comp
         where ib.v is not null
       ),
       item_terms as (
         -- only items that have every component of the derived field
         select t.* from item_terms_all t
         where (select count(*) from item_terms_all t2 where t2.item_id = t.item_id and t2.key = t.key)
             = (select count(*) from derived_terms d2 where d2.key = t.key)
       ),
       ```
       `item_vals`, `period_terms` and `period_shares` stay as they are. Update the migration
       comment, and D10 step 1.
     - **4b check 6:** `calories` 600, `field_counts.calories` 2, shares 0.3 / 0.4 / 0.3. Update the
       hand-worked table so Mon and Thu calories read "— (partial)". 4a's cross-check `calories`
       expression becomes `case when p is not null and c is not null and f is not null then
       4*p + 4*c + 9*f end`.
     - **UI (Step 6c):** the split legend's grams must come from the same days as the split.
       Today it shows `Values[comp]`, which averages over the macro's own days (Protein 43.75 g
       over 4 days, next to a split built from 2 days). Instead compute
       `Values[key] × Shares[key][comp] / Weights[comp]` client-side, which is the component's
       average grams over the calorie days (600 × 0.3 / 4 = 45 g). This is still config-driven,
       needs no RPC change, and drops the "grams match 4a's averages" clause from Step 8 check 2.
     - Roughly 15 lines of SQL, 4 changed assertions and 1 changed C# expression.
   - **(b) Keep the current calculation, but show completeness on the Calories card.** Cost:
     - **RPC (Step 2):** a sixth return column, `field_complete jsonb`, holding
       `{derived_key: n}`, where n is the number of items with every component. It's computed with
       the same count comparison as (a)'s `item_terms`, but used only for counting. Changing the
       return type is free now because nothing has been pushed yet.
     - **Client (Step 5):** `ReportPeriodRow` gains `Dictionary<string, int> Complete`.
     - **UI (Step 6c):** when `Complete[key] < Counts[key]`, the basis line becomes "avg per day ·
       4 days · 2 fully logged". A caption under the split reads "includes 2 partially logged days",
       in `var(--colorPaletteMarigoldForeground1, #c19c00)`.
     - **4b check 6:** add an assertion that `field_complete.calories` is 2. Values unchanged.
     - Roughly 10 lines of SQL, 1 record field, about 10 lines of Razor and 1 assertion.
   - **(c) Keep the current behaviour (what round 3 had).** Partial days count with whatever they
     have, and the card shows only its usual "· n days" basis line. Cost: none. The Section 5 bullet
     records it as your choice rather than an unexamined default.

   If you choose (a) or (b), the Step 2 SQL and Step 4b script change from what was run on the
   local stack, so re-run them there before Step 4 (Section 0.2 describes how).

**Decided in this plan; no input needed unless you disagree:**
- Calories and the % split are computed **in the RPC**, from config (D10). Not a user-facing choice.
- Weekly calories = the **average of each day's calories** (each day's 4p + 4c + 9f), and the split
  is energy-weighted over the same days (D10). When every day has all three macros (always true
  for Scan Plate entries) this is mathematically identical to computing from the week's averaged
  grams. *Which* days count toward calories when some macros are missing is A.4, still open.
- A day where a field was never logged is **left out of that field's average**, not counted as 0
  (D9). For weight that's clearly right (no weigh-in is not 0 lbs). The card shows how many days
  each average is based on.

Also ask for explicit go-ahead at each of these steps:
- Step 4's `supabase db push --linked`, which changes the shared dev database;
- Step 8's push to `main`, which triggers `deploy-pages.yml`.

---

## 0. Ground truth (checked read-only against dev and the repo, 2026-11-15)

### 0.1 The Nutrition Tracker data model as built

- **One item per day** (`item_label = 'meal date'`). It moves forward through
  breakfast → brunch → lunch → linner → dinner (`sequence_order` 1–5). All five stages use the same
  checklist keys (`protein_g, carbs_g, fat_g, fiber_g, sugar_g, weight_lbs`).
- **`move_stage` (`20261113000000`) clears the shared keys from `item.data` on every forward move**,
  including forward skips. Backward moves clear nothing. So right after a forward move, `item.data`
  holds only the current stage's values.
- **Values are running totals per stage, not deltas.** Scan Plate writes `existing + scanned`.
  Chat corrections write absolute values through the agent's untyped `update_data` patch, so a
  value *can* arrive as a JSON string.
- **`fiber_g` and `sugar_g` are sub-components of `carbs_g`**, not extra carbohydrate mass.
  `supabase/functions/scan-plate/index.ts` rejects any item where `fiber_g + sugar_g > carbs_g + 1`
  (line 79) and tells the model so in its prompt (line 175). Chat writes aren't validated this way,
  but nothing in this plan depends on the inequality holding; it only means fiber and sugar must
  not be separate calorie or % slices (D10).
- **`weight_lbs` is a once-a-day reading**, not an amount that accumulates across meals.
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
| `8c4775d6` | 2026-11-15 14:30 | lunch (re-checked for round 4) | 2 forward, 22:25 UTC |

Round-4 re-check (read-only, 2026-11-15): `8c4775d6` moved breakfast → lunch in two forward moves
after round 3 was written. Those moves happened before Step 1 exists, so its earlier meals are gone
the same way `a831e45f`'s are (D2). All four items hold all three of protein/carbs/fat (A.4).

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
  migration `20261016130000`), but every later migration except `20261023120000` (its
  `chat_messages` table already exists locally) applies cleanly inside a transaction. **The Step 2
  SQL and the Step 4b script in this draft were run that way on 2026-11-15, inside
  `begin … rollback`, and passed** (see Step 2 notes). Nothing persisted locally.

### 0.3 The architectural rule this plan follows

- One generic page or RPC per concern.
- Workflow-specific behaviour lives in data and config (`stages.checklist` /
  `optional_checklist` jsonb), not in per-workflow code.
- The page has two existing kinds of exception: branching on `item_label == "job"` for display,
  and capability gates keyed on well-known field names (`vin`, `protein_g`, `scheduled_at`, the
  `_g`/`_lbs` unit suffixes).
- **This plan adds no new exception of either kind.** The Report is gated only on
  `workflows.report_config` being non-null. Every per-field behaviour (label, unit, both
  aggregation levels, derived-field weights, split display) is read from that config. In
  particular, the Atwater factors 4/4/9 live in Nutrition's config row, not in SQL or C#.

### 0.4 Styling tokens in use

- `--app-accent` (`#2b88d8`).
- Status colours use a Fluent token with a hex fallback, e.g.
  `var(--colorPaletteRedForeground1, #c00)`.
- Buttons use `Appearance="ButtonAppearance.Primary"`.
- Fluent UI Blazor v5.0.1.

## 1. What gets built

1. **Snapshot on clear.** `move_stage` records the values it clears inside its own
   `item.stage_changed` event (`data = {"cleared": {...}}`). Unchanged from `final-plan.md`.
2. **Config.** A nullable `workflows.report_config jsonb` sets the period, the fields to report,
   each field's **two independent aggregation settings** (`item_agg`, `period_agg`), and optional
   **derived fields** (a weighted sum of other fields, e.g. calories). `null` means no report.
3. **Read path.** One `report_series` RPC (security invoker) returns per-period values, per-field
   counts and derived-field shares, in a caller-supplied timezone. Snapshots are deduped per
   (item, departing stage, field).
4. **UI.** A generic page `/workflow/{WorkflowId}/report` (`WorkflowReport.razor`), linked from
   `WorkflowDetail`'s list view when `report_config` is set.
5. **Content.** Only Nutrition Tracker gets a `report_config`: weekly, showing average daily
   calories with a protein/carbs/fat % split, average weight, average daily fiber, average daily
   sugar, and days included. The mechanic gets a rolled-back dry run only.

**Removed from `final-plan.md`:** goals entirely — the `report_goals` table, `goal_direction`, the
goal-in-effect rule, the goal UI (progress bars, "Set goal" form, goal step line on the trend,
"Goal met on N of M"), and `GetReportGoalsAsync`/`AddReportGoalAsync`. The user explicitly does not
want goal or target tracking for this feature.

## 2. Decisions

### D1. Per-stage values are captured at write time and deduped per stage at read time

Unchanged from `final-plan.md`.

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
(60 vs 75). Round-2 sanity-check re-verified this by hand-trace; it is unchanged here.

**Residual.** Backing out to an earlier stage and moving forward again without editing replaces
that stage's original snapshot with the carried-over values. Deferred (Decision A.2, Section 6).

**Rejected alternatives:** replaying `data_changed` events (complex, re-interprets history whenever
a checklist is edited, can't tell pre-`20261113000000` moves apart); per-stage namespaced keys
(break the shared-checklist design); a separate snapshot table (`stage_changed.data` already
exists and is unused).

### D2. No backfill

`a831e45f`'s moves have no `cleared` data, so local 11-12 reports Dinner's live values only.
`8c4775d6` (11-15) is in the same position since its round-4-era moves to lunch: it reports Lunch's
live values only. Any further forward move made before Step 4's push loses data the same way. The
migration comment says so.

### D3. Config: `workflows.report_config jsonb`

Top level:

| property | values | default | validated by CHECK | notes |
|---|---|---|---|---|
| `period` | `day`, `week`, `month` | required | yes | ISO weeks (Monday start) = `date_trunc('week')`. Kept configurable (it already was, and costs nothing); Nutrition sets `week`. |
| `fields` | non-empty array | required | yes (each element too, see below) | Display order = array order. |
| `show_count` | bool | `false` | no (UI-only) | Shows the items-per-period card ("Days included"). |
| `count_label` | text | `"{ItemLabelPlural}"` | no (UI-only) | Title of the count card. Nutrition: `"Days included"`. |
| `item_noun` | text | the workflow's `item_label` | no (UI-only) | Used in "avg per day · 5 days". Nutrition: `"day"` (its `item_label` is `meal date`). |

Each `fields[]` element is **either a base field or a derived field**:

| property | base field | derived field | notes |
|---|---|---|---|
| `key` | required, non-empty string, unique | required, non-empty string, unique | Base: a `data.*` key. Derived: an output name only. |
| `item_agg` | **required**: `sum`, `avg`, `last` | **must be absent** | How one item's per-stage values combine (D9). |
| `period_agg` | **required**: `sum`, `avg`, `last` | **required**: `sum`, `avg`, `last` | How a period's item values combine (D9). |
| `weights` | absent | **required**: non-empty object of `{base_key: number > 0}` | Each key must name a *base* field in the same array. No derived-of-derived. |
| `split` | — | bool, default `false` (UI-only) | Show each component's share of the derived total (D10). |
| `hidden` | bool, default `false` (UI-only) | bool, default `false` (UI-only) | Compute and return, but no card of its own. |
| `label` | text, default: key humanized | same | |
| `unit` | text, default `""` | same | No fallback to the `_g`/`_lbs` suffix convention. |
| `unit_position` | `prefix`/`suffix`, default `suffix` (UI-only) | same | |

**Why both aggregation settings are required, with no default.** With one knob, defaulting `agg`
to `sum` was harmless. With two, a silently defaulted level is exactly the bug this redesign
fixes (weight summed across meals, or fiber summed across a week). Every field states both, and
the CHECK enforces it. This also rejects any stale config still using the old single `agg` key.

**What the CHECK validates, and what it doesn't.** It validates everything the RPC relies on:
object shape, `period`, non-empty `fields`, each element's `key`/`item_agg`/`period_agg`/`weights`
rules above, and unique keys. It does not validate UI-only properties (`label`, `unit`,
`unit_position`, `split`, `hidden`, `show_count`, `count_label`, `item_noun`); the client parser
defaults those without throwing.

Why config lives on `workflows`, as jsonb: it follows the `checklist` precedent (static,
migration-authored metadata); a report spans stages, so it belongs to the workflow; the nullable
column doubles as the on/off switch. Rejected: a child table, and hints on `checklist` entries.

### D4. (Removed: goals.)

The user does not want goal or target tracking. No `report_goals` table, no `goal_direction`, no
goal-in-effect rule, no goal UI.

### D5. Grouping uses `created_at` in the viewer's timezone

Unchanged.
- `period_start = date_trunc(period, created_at AT TIME ZONE p_tz)`.
- `p_tz` comes from `Intl.DateTimeFormat().resolvedOptions().timeZone`.
- `ItemDisplayName` switches to `CreatedAt.ToLocalTime()` so the list and the report agree. That
  name is also what goes to `agent-loop` as `selected_item_display_name`, and becomes more correct
  there too.
- Known gap, deferred: for mechanic revenue, bucketing by invoice date might fit better.

### D6. Aggregation is one server-side RPC

- `report_series(p_workflow_id, p_from, p_to, p_tz)` returns one row per non-empty period:
  `(period_start date, item_count bigint, field_values jsonb, field_counts jsonb, field_shares jsonb)`.
  - `field_values`: `{key: number}` for every field (base and derived, hidden or not) with a
    non-null period value.
  - `field_counts`: `{key: n}` — how many items contributed a non-null value to that field. This
    is the denominator of an `avg`, shown as "5 days" / "2 weigh-ins".
  - `field_shares`: `{derived_key: {component_key: fraction}}` (D10). Fractions rounded to 4 dp.
- `item_count` counts every item in the period, including ones with no data. This is "Days
  included".
- Security invoker; RLS scopes it like `search_items`.
- Values go through `private.jsonb_numeric`: numbers pass through; `"$1,250.00"`/`"30"`-style
  strings are parsed; anything else becomes null. The string branch stays because the agent's
  `update_data` patch is untyped; Step 4b tests it (check 0, and check 5 feeds a real `"25"`).

### D7. UI: one generic page; inline SVG, no chart library

- Only Fluent components already used in `WorkflowDetail`: `FluentCard`, `FluentStack`,
  `FluentButton`, `FluentLink`, `FluentSpinner`, `FluentMessageBar`.
- Colours come only from the Section 0.4 tokens plus palette tokens with hex fallbacks (Step 6c).

### D8. The agent loop is untouched

Chat access to report numbers is out of scope.

### D9. Two independent aggregation levels: `item_agg` and `period_agg` (new)

`final-plan.md` had one `agg` per field, applied twice: across an item's per-stage values, then
across a period's items. Those are different questions, and for this report they need different
answers:

| field | within a day (`item_agg`) | across the week (`period_agg`) |
|---|---|---|
| protein / carbs / fat / fiber / sugar | `sum` — a day's total is breakfast + … + dinner | `avg` — average daily intake |
| weight | `last` — the day's latest reading; one weigh-in, never summed across meals | `avg` — average of the daily readings |
| calories (derived) | — computed per day from that day's p/c/f (D10) | `avg` — average daily calories |

One knob can't express "sum then average" or "last then average", so the config now carries both,
independently.

**Naming.** `item_agg` / `period_agg`, not `within_day_agg` / `across_days_agg`. The engine is
generic: for the mechanic an item is a job, not a day, and the period may be a day, week or month.
The names say which level they combine at, in the engine's own vocabulary (`item`, `period`). The
Nutrition-specific reading ("within a day", "across the week") lives in this doc and the migration
comment.

**Semantics.**
- `item_agg`, over the deduped per-stage segments (D1): `sum` and `avg` ignore null segments;
  `last` takes the non-null value with the highest `seq` (the live value counts as the latest). So
  for weight: entered at breakfast and never again → breakfast's reading; re-weighed at lunch → the
  lunch reading.
- `period_agg`, over the period's item values: `sum` and `avg` ignore items whose value is null
  (the field was never logged that day); `last` takes the non-null value of the latest-created
  item. If two items have identical `created_at` (possible, e.g. two items created in one
  transaction share `now()`), the one with the greater `items.id` (Postgres uuid ordering) wins.
  That choice is arbitrary but deterministic, and it's in the SQL (`order by its.created_at desc,
  its.id desc`). `avg` is therefore "average over the days that have a value", and `field_counts`
  reports that denominator.
- `item_agg: last` needs no tie-break: it orders by `seq`, which never ties (Section 0.1), and the
  live segment's sentinel `seq` appears at most once per (item, field), because an item has only
  one current stage.
- Allowed values are the same set (`sum`, `avg`, `last`) at both levels.

**This resolves round-2 sanity-check finding #6 ("avg of avg").** That finding existed only because
one `agg` was applied at both levels, so `avg` silently meant an unweighted average of averages.
Now each level applies exactly the aggregate configured for it, once. The shipped Nutrition config
uses `avg` only at the period level, over per-day values that were summed (or `last`-ed) within the
day — which is exactly "average daily intake". There is no hidden second averaging step left to
document, so this is no longer an open concern.

The one place an average of averages could still appear is a UI summary across several weekly
averages. This draft deliberately has **no** multi-period summary line (`final-plan.md`'s "Previous
N periods" average is dropped along with goals); the trend shows the weekly values instead.

**Rejected alternatives:**
- *Keep one `agg` and infer the other level from the key or unit* (e.g. `_lbs` → `last`). That's a
  field-name gate, against Section 0.3.
- *A single compound value* (`"agg": "sum/avg"`). Two plain properties are easier to validate in
  the CHECK and to read.
- *Defaults for either level.* See D3: a silent default is the bug class being fixed.

### D10. Calories and the % split are computed in the RPC, from config (new)

**Shape.** A derived field: `{"key": "calories", "label": "Calories", "unit": "kcal",
"period_agg": "avg", "weights": {"protein_g": 4, "carbs_g": 4, "fat_g": 9}, "split": true}`.
Fiber and sugar are not components: they are already inside `carbs_g` (Section 0.1), so slicing
them separately would double-count. The 3-way split is protein / carbs / fat only.

**Computation, in `report_series`:**
1. Per item: `calories = Σ weight_k × item_value_k` over components that have a non-null item
   value (an item missing fat contributes 4p + 4c). An item with none of the three components has
   null calories and is left out of the average. **Pending A.4:** option (a) changes this to
   "only items with every component"; option (b) keeps it and adds a completeness count.
2. Per period: `period_agg` (`avg`) over the items' calories → **average daily calories**.
3. Shares, per period: `Σ_items(weight_k × value_k) / Σ_items(calories)` for each component, over
   exactly the same items as step 2. Returned in `field_shares`.

**Why average the per-day calories, rather than derive calories from the averaged grams.** Daily
calories is a per-day quantity; "average daily calories" is literally the mean of the daily
figures. Computing per day first also keeps calories and the split on one consistent set of days.
Deriving from averaged grams (`4·avg(p) + 4·avg(c) + 9·avg(f)`) is identical when every day has all
three macros (linearity), but goes wrong when days differ: `avg(p)` and `avg(f)` would be over
different sets of days, mixing denominators. Step 4b check 6 has exactly that case (one day with
protein only) and asserts the per-day result.

**Why the split is energy-weighted (ratio of week totals), not an average of daily percentages.**
Averaging daily percentages gives a light snack day the same weight as a full day. The ratio of
summed energies is the true share of the week's calories, and equals the ratio of the week's
average macro calories over the same days.

**Why in the RPC, not in Blazor.**
- Correctness: step 1 needs per-day values. The RPC returns period aggregates only, so a client-side
  computation could only use averaged grams, which is the mixed-denominator approach above.
- Architecture: hardcoding 4/4/9 in either SQL or C# would be a Nutrition-specific field-name
  exception (Section 0.3). As config, the RPC stays generic: any workflow can declare a weighted-sum
  field.
- One source of truth if chat ever gets report access (D8, out of scope).

**Rejected:**
- *Client-side from the RPC's protein/carbs/fat:* above.
- *A hardcoded `calories` column in the RPC:* field-name gate.
- *A general expression language for derived fields:* far more than a weighted sum needs.

**Constraints, deliberately narrow:** weights must be numbers > 0 (shares are meaningless with
negative weights; a future "profit" field would need this relaxed and `split` restricted to
all-positive weights), and components must be base fields (no derived-of-derived).

**Known approximation.** Atwater 4 kcal/g on *total* carbs counts fiber at 4 kcal/g (it's closer to
~2). This matches the user's spec and scan-plate's own plausibility check
(`index.ts:120`), and is not corrected here.

## 3. Steps

### Step 1. Migration: `move_stage` snapshots what it clears

**Unchanged from `final-plan.md`.** File:
`supabase/migrations/20261115000000_move_stage_records_cleared_values.sql`. This is the full,
literal file. It is `20261113000000`'s body with exactly three changes, marked `-- NEW`/`-- CHANGED`.

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

```sql
-- Generic per-workflow Report (2026-11-15). First (and only) consumer: Nutrition Tracker's weekly
-- report -- average daily calories with a protein/carbs/fat split, average weight, average daily
-- fiber and sugar, days included. Built generically anyway: like stages.checklist, which fields
-- matter and how is per-workflow jsonb config read by one generic page, not code. jsonb on
-- workflows rather than a child table for the same reason checklist is (20261104020000): static,
-- migration-authored metadata read wholesale. On workflows, not stages, because a report spans
-- stages. null = this workflow has no report (and the UI shows no Report link). No goals: the user
-- explicitly does not want target tracking here.
--
-- Two aggregation levels per field, both required, no defaults:
--   item_agg   -- combines one item's per-stage values (a Nutrition day: sum its meals; weight:
--                 last reading of the day)
--   period_agg -- combines a period's item values (a Nutrition week: average the days)
-- One shared "agg" can't say "sum within a day, then average across the week", and a silently
-- defaulted level is how weight ends up summed across meals. sum/avg ignore nulls at both levels.
-- A derived field has "weights" instead of item_agg: per item, sum(weight * component value) over
-- the base components that have a value; then period_agg as usual. Calories = 4p + 4c + 9f lives
-- in config, not code. fiber_g/sugar_g are sub-components of carbs_g (scan-plate enforces
-- fiber + sugar <= carbs), so they are deliberately NOT calorie components.
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
               when jsonb_typeof(f -> 'key') <> 'string' or (f ->> 'key') = '' then false
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
-- per-stage values are combined with item_agg; derived fields are then computed per item; then
-- every field's item values are combined with its period_agg.
-- field_counts = items with a non-null value per field (the denominator of an avg).
-- field_shares = per derived field, each component's share of the derived total, over the same
-- items as the derived value itself (energy-weighted, not an average of daily percentages).
-- security invoker: RLS on workflows/items/item_events scopes rows, same as search_items. No
-- range cap, also like search_items.
create function public.report_series(p_workflow_id uuid, p_from date, p_to date, p_tz text default 'UTC')
returns table (period_start date, item_count bigint, field_values jsonb, field_counts jsonb, field_shares jsonb)
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
  item_terms as (
    -- derived fields: one weighted term per (item, derived field, component that has a value)
    select ib.item_id, d.key, d.period_agg, d.comp, d.weight * ib.v as e
    from derived_terms d
    join item_base ib on ib.key = d.comp
    where ib.v is not null
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
  ),
  period_terms as (
    select its.period_start, t.key, t.comp, sum(t.e) as e,
           sum(sum(t.e)) over (partition by its.period_start, t.key) as total
    from item_terms t
    join its on its.id = t.item_id
    group by its.period_start, t.key, t.comp
  ),
  period_shares as (
    select pt.period_start, pt.key, jsonb_object_agg(pt.comp, round(pt.e / pt.total, 4)) as shares
    from period_terms pt
    where pt.total > 0
    group by pt.period_start, pt.key
  )
  select p.period_start,
         count(*) as item_count,
         coalesce((select jsonb_object_agg(pv.key, pv.v) from period_vals pv
                   where pv.period_start = p.period_start and pv.v is not null), '{}'::jsonb),
         coalesce((select jsonb_object_agg(pv.key, pv.n) from period_vals pv
                   where pv.period_start = p.period_start and pv.n > 0), '{}'::jsonb),
         coalesce((select jsonb_object_agg(ps.key, ps.shares) from period_shares ps
                   where ps.period_start = p.period_start), '{}'::jsonb)
  from its p
  group by p.period_start
  order by p.period_start;
$$;
revoke all on function public.report_series(uuid, date, date, text) from public;
grant execute on function public.report_series(uuid, date, date, text) to authenticated;

-- Nutrition Tracker's weekly report. Matched by name since ids differ between dev and prod (same
-- pattern as 20261112000000). Within a day: macros sum across meal stages, weight is the day's
-- last reading. Across the week: everything averages over the days that have a value.
-- protein/carbs/fat are hidden as cards (they appear inside the Calories split instead).
update public.workflows
set report_config = '{
  "period": "week",
  "show_count": true,
  "count_label": "Days included",
  "item_noun": "day",
  "fields": [
    {"key": "calories",   "label": "Calories", "unit": "kcal", "period_agg": "avg",
     "weights": {"protein_g": 4, "carbs_g": 4, "fat_g": 9}, "split": true},
    {"key": "protein_g",  "label": "Protein", "unit": "g",   "item_agg": "sum",  "period_agg": "avg", "hidden": true},
    {"key": "carbs_g",    "label": "Carbs",   "unit": "g",   "item_agg": "sum",  "period_agg": "avg", "hidden": true},
    {"key": "fat_g",      "label": "Fat",     "unit": "g",   "item_agg": "sum",  "period_agg": "avg", "hidden": true},
    {"key": "weight_lbs", "label": "Weight",  "unit": "lbs", "item_agg": "last", "period_agg": "avg"},
    {"key": "fiber_g",    "label": "Fiber",   "unit": "g",   "item_agg": "sum",  "period_agg": "avg"},
    {"key": "sugar_g",    "label": "Sugar",   "unit": "g",   "item_agg": "sum",  "period_agg": "avg"}
  ]
}'::jsonb
where name = 'Nutrition Tracker' and report_config is null;
```

Notes:
- **Verified on the local stack (2026-11-15), in a rolled-back transaction**, after applying the
  missing intermediate migrations plus Step 1:
  - The Step 4b script below printed `PASS`. Its check 1 is the reproducible CHECK verification:
    **13 bad configs**, each rejected as `check_violation` (never another error). They are: missing
    `fields`, missing `period`, unknown `period`, a top-level array, empty `fields`, object `fields`,
    a legacy `agg`-only field, a missing `period_agg`, an unknown agg (`max`), duplicate keys, an
    unknown component, a string weight, and `item_agg` on a derived field.
  - Acceptance is covered by the shipped Nutrition config applying (4b's SETUP guard fails if
    `report_config` is still null) and by `null` being the column's state for every other workflow.
  - Round 3 said "24 probes", but nothing saved in this document reproduces that number, so it's no
    longer claimed. Other validator branches are correct by reading the SQL, not by any saved test:
    JSON-null agg, numeric/empty/missing `key`, scalar element, derived component, empty/array/null
    `weights`, zero weight, and null/missing `fields`. To make them executable, add one JSON literal
    per case to check 1's array, e.g.
    `'{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "period_agg": "avg", "weights": {"x": 0}}]}'`.
    Then re-run 4b locally before relying on it, because those added lines have not been run.
- **`jsonb_numeric` edge case.** A non-numeric live value still counts as that stage's latest
  segment, with value null, so the stage contributes nothing (no fallback to an older snapshot).
  The stage UI shows the same unparseable value.
- **Indexes.** `items(workflow_id)` and `item_events(item_id, seq)` are enough at these volumes.
- **Hidden components must stay in `fields`.** Calories needs their per-day values, which only
  base fields produce. The validator enforces that components are base fields in the same array.

### Step 3. (Removed: the `report_goals` migration.)

### Step 4. Push and verify the database side

**Needs the user's explicit go-ahead before `db push`. It changes the shared dev database.**

```bash
cd /home/mmcbride/micah/claude/workflow-app
diff <(sed -n '/create or replace function/,$p' supabase/migrations/20261113000000_move_stage_clears_shared_fields.sql) \
     <(sed -n '/create or replace function/,$p' supabase/migrations/20261115000000_move_stage_records_cleared_values.sql)
# expect ONLY: the v_cleared declaration, the NEW capture block, and the insert's added data column/value
supabase db push --linked --dry-run   # expect exactly the two new files
supabase db push --linked
```

**4a. Read-only check against real data.** Run it right after the push, before any Nutrition item
moves forward (a move after the push writes a snapshot, which the cross-check below doesn't model).
These go straight to SQL, not through PostgREST, so a stale PostgREST schema cache can't show up
here; it would first show up in Step 8 check 2.

```bash
supabase db query --linked "select * from public.report_series(
  (select id from public.workflows where name = 'Nutrition Tracker'),
  '2026-11-09', '2026-11-15', 'America/Chicago')"
```

Expect one row, `period_start` 2026-11-09, `item_count` 4 (more if the user has created items
since), every configured key present in `field_values`, and a `calories` entry in `field_shares`
whose three fractions sum to ~1. Then cross-check against a direct computation from live data
(valid because no item in that week has a `cleared` snapshot yet):

```bash
supabase db query --linked "with i as (
  select private.jsonb_numeric(data->'protein_g') p, private.jsonb_numeric(data->'carbs_g') c,
         private.jsonb_numeric(data->'fat_g') f, private.jsonb_numeric(data->'fiber_g') fi,
         private.jsonb_numeric(data->'sugar_g') s, private.jsonb_numeric(data->'weight_lbs') w
  from public.items
  where workflow_id = (select id from public.workflows where name = 'Nutrition Tracker')
    and date_trunc('week', created_at at time zone 'America/Chicago')::date = '2026-11-09')
select count(*) n, avg(p) protein, avg(c) carbs, avg(f) fat, avg(fi) fiber, avg(s) sugar, avg(w) weight,
       avg(case when coalesce(p, c, f) is not null then 4*coalesce(p,0) + 4*coalesce(c,0) + 9*coalesce(f,0) end) calories
from i"
```

Every number must match the RPC row. If they differ, first check whether any of those items has a
`stage_changed` event with non-null `data` (then the cross-check, not the RPC, is out of date).

Timezone bucketing is checked deterministically in 4b (check 7), not against real data, since all
four real items fall in one week in both UTC and Chicago.

**4b. Write-path checks.** Save as `scripts/report_series_dev_check.sql`; safe to re-run. Run with
`supabase db query --linked -f scripts/report_series_dev_check.sql`.
- **Success:** an error message starting with `PASS`.
- **Failure:** anything else (`FAIL …`, `SETUP …`, or any other error). Nothing persists either way.

All test items are back-dated into the week of Mon 2026-01-05, which predates the Nutrition
workflow, so real data never mixes into the asserted numbers (the SETUP guard checks this). That
replaces `final-plan.md`'s "baseline delta" trick, which doesn't work once the period value is an
average across items.

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
  v_ev jsonb; v_fv jsonb; v_fc jsonb; v_fs jsonb; v_n bigint; v_rows int;
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
    '{"period": "week", "fields": [{"key": "x", "item_agg": "sum", "period_agg": "avg"}, {"key": "k", "item_agg": "sum", "period_agg": "avg", "weights": {"x": 4}}]}'
  ] loop
    begin
      update public.workflows set report_config = c::jsonb where id = v_wf;
      raise exception 'FAIL check: accepted %', c;
    exception when check_violation then v_rej := v_rej + 1; end;
  end loop;

  ---------------------------------------------------------------- become the real user; create the test days
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select id into d_a from public.create_item(v_wf, '{}'::jsonb);   -- Mon: the stage-movement day
  select id into d_b from public.create_item(v_wf, '{"protein_g": 40, "carbs_g": 40, "fat_g": 20, "fiber_g": 6, "sugar_g": 8, "weight_lbs": 178}'::jsonb);
  select id into d_c from public.create_item(v_wf, '{}'::jsonb);   -- Wed: nothing logged
  select id into d_d from public.create_item(v_wf, '{}'::jsonb);   -- Thu: protein only, as a string
  select id into d_e from public.create_item(v_wf, '{"protein_g": 50, "carbs_g": 80, "fat_g": 20, "fiber_g": 8, "sugar_g": 15}'::jsonb);
  select id into d_f from public.create_item(v_wf, '{}'::jsonb);   -- Sun 21:00 Chicago = Mon UTC

  reset role;   -- back-dating needs the CLI role; RLS/grant paths are exercised by everything else
  update public.items set created_at = '2026-01-05 18:00+00' where id = d_a;
  update public.items set created_at = '2026-01-06 18:00+00' where id = d_b;
  update public.items set created_at = '2026-01-07 18:00+00' where id = d_c;
  update public.items set created_at = '2026-01-08 18:00+00' where id = d_d;
  update public.items set created_at = '2026-01-09 18:00+00' where id = d_e;
  update public.items set created_at = '2026-01-12 03:00+00' where id = d_f;
  set local role authenticated;

  ---------------------------------------------------------------- 2. snapshot + within-day sum / last
  perform public.update_data(d_a, '{"protein_g": 30, "weight_lbs": 180}');
  perform public.move_stage(d_a, v_br);
  select data into v_ev from public.item_events
  where item_id = d_a and event_type = 'item.stage_changed' order by seq desc limit 1;
  if v_ev is distinct from '{"cleared": {"protein_g": 30, "weight_lbs": 180}}'::jsonb then
    raise exception 'FAIL snapshot: %', v_ev;
  end if;
  perform public.update_data(d_a, '{"protein_g": 20}');
  select field_values into v_fv from public.report_series(v_wf, v_wk, v_wk, v_tz);
  if (v_fv ->> 'protein_g')::numeric is distinct from 50 or (v_fv ->> 'weight_lbs')::numeric is distinct from 180 then
    raise exception 'FAIL simple: % (want protein 50, weight 180)', v_fv;
  end if;

  ---------------------------------------------------------------- 3. back up, correct, forward again
  perform public.move_stage(d_a, v_b);
  perform public.update_data(d_a, '{"protein_g": 35}');
  perform public.move_stage(d_a, v_br);
  perform public.update_data(d_a, '{"protein_g": 20}');
  select field_values into v_fv from public.report_series(v_wf, v_wk, v_wk, v_tz);
  if (v_fv ->> 'protein_g')::numeric is distinct from 55 or (v_fv ->> 'weight_lbs')::numeric is distinct from 180 then
    raise exception 'FAIL correction: % (want protein 55 [85 = no dedupe], weight 180)', v_fv;
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

  ---------------------------------------------------------------- 5. within-day "last": a later weigh-in wins
  perform public.update_data(d_a, '{"weight_lbs": 181}');
  perform public.update_data(d_d, '{"protein_g": "25"}');

  ---------------------------------------------------------------- 6. across-day avg, derived calories, shares, counts
  select item_count, field_values, field_counts, field_shares into v_n, v_fv, v_fc, v_fs
  from public.report_series(v_wf, v_wk, v_wk + 6, v_tz);
  if v_n is distinct from 6
     or round((v_fv ->> 'protein_g')::numeric, 2) is distinct from 43.75
     or (v_fv ->> 'carbs_g')::numeric   is distinct from 60
     or (v_fv ->> 'fat_g')::numeric     is distinct from 20
     or (v_fv ->> 'fiber_g')::numeric   is distinct from 7
     or (v_fv ->> 'sugar_g')::numeric   is distinct from 11.5
     or (v_fv ->> 'weight_lbs')::numeric is distinct from 179.5
     or (v_fv ->> 'calories')::numeric  is distinct from 385
     or (v_fc ->> 'calories')::int is distinct from 4
     or (v_fc ->> 'carbs_g')::int  is distinct from 2
     or (v_fc ->> 'weight_lbs')::int is distinct from 2
     or (v_fs -> 'calories' ->> 'protein_g')::numeric is distinct from 0.4545
     or (v_fs -> 'calories' ->> 'carbs_g')::numeric   is distinct from 0.3117
     or (v_fs -> 'calories' ->> 'fat_g')::numeric     is distinct from 0.2338 then
    raise exception 'FAIL week: count % values % counts % shares %', v_n, v_fv, v_fc, v_fs;
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

  raise exception 'PASS (all rolled back): jsonb_numeric ok, % bad configs rejected, snapshot ok, within-day 50/55/60, week avg/calories/shares ok, tz ok, mechanic data null, enforce: %',
    v_rej, v_fp_note;
end;
$$;
```

How check 6's expected numbers come about (the test week, Chicago):

| day | protein | carbs | fat | fiber | sugar | weight | calories |
|---|---|---|---|---|---|---|---|
| Mon (d_a) | 40 + 20 = 60 (bfast + brunch, after dedupe) | — | — | — | — | 181 (`last`: lunch re-weigh beats breakfast's 180) | 240 |
| Tue (d_b) | 40 | 40 | 20 | 6 | 8 | 178 | 500 |
| Wed (d_c) | — | — | — | — | — | — | — |
| Thu (d_d) | 25 (string `"25"`) | — | — | — | — | — | 100 |
| Fri (d_e) | 50 | 80 | 20 | 8 | 15 | — | 700 |
| Sun 21:00 (d_f) | — | — | — | — | — | — | — |
| **week** | avg 43.75 (n=4) | 60 (n=2) | 20 (n=2) | 7 (n=2) | 11.5 (n=2) | 179.5 (n=2) | **385** (n=4) |

- `item_count` 6 ("Days included"), including the two empty days.
- Shares: protein energy 700, carbs 480, fat 360, of 1540 → 0.4545 / 0.3117 / 0.2338.
- The old single-`agg` design would have produced protein 175 (sum across days) and weight 359
  (sum of 181 and 178), or with `avg` at both levels, weight 180.5 for Mon (average of 180 and 181
  within the day). Those are the failures D9 fixes.
- Deriving calories from averaged grams would give 4·43.75 + 4·60 + 9·20 = 595, not 385, because
  the three averages have different denominators. That is the D10 choice being asserted.

Notes:
- Each `FAIL` names its check and prints actual values.
- Each nested `exception when check_violation` rolls back only its own subtransaction. `FAIL`
  raises are P0001, which those handlers don't catch, so they propagate.
- Check 9's handler re-raises anything that isn't a `forward skip…` error.
- The CHECK probes run as the CLI's role, before the role switch, so they don't depend on
  `workflows_update` RLS.
- **Fallback** if the Management API refuses `set local role` or `reset role` inside `DO`
  (Section 4): run the same file in the dashboard SQL editor; if that's refused too, Step 8 check 4
  covers checks 2–3 on real data.

### Step 5. Client API (`web/Services/WorkflowApiClient.cs`)

**New records:**

```csharp
// Generic Report (2026-11-15) -- parsed from workflows.report_config; see
// 20261115010000_add_workflow_report_config.sql for the shape. ItemAgg is null for a derived field
// (Weights non-null); both aggregation levels are required by the DB CHECK.
public record ReportField(string Key, string Label, string Unit, bool UnitPrefix,
    string? ItemAgg, string PeriodAgg, IReadOnlyDictionary<string, double>? Weights,
    bool Split, bool Hidden);
public record ReportConfig(string Period, bool ShowCount, string? CountLabel, string? ItemNoun,
    List<ReportField> Fields);
public record ReportPeriodRow(DateOnly PeriodStart, long ItemCount,
    Dictionary<string, double> Values, Dictionary<string, int> Counts,
    Dictionary<string, Dictionary<string, double>> Shares);
```

**Changed: `WorkflowSummary`.** Trailing optional parameter:
`public record WorkflowSummary(string Id, string Name, string ItemLabel, ReportConfig? Report = null);`.
- `GetWorkflowAsync` adds `report_config` to its `select` and parses it with a private
  `ParseReportConfig(JsonNode?)`.
- `GetWorkflowsAsync` is unchanged; its 3-argument construction still compiles.

**`ParseReportConfig` rules.** The CHECK guarantees the RPC-relevant shape, so the parser is a
defensive mirror, never a second source of defaults for aggregation. Nothing throws.

| input | result |
|---|---|
| null node | `null` |
| `show_count` not a JSON boolean | `false` |
| `count_label` missing or not a string | `CountLabel = null`; the count card's title falls back to the workflow's `ItemLabelPlural` |
| `item_noun` missing or not a string | `ItemNoun = null`; the basis-line noun falls back to the workflow's `item_label` |
| field with missing or non-string `key` | field skipped |
| field `period_agg` not `sum`/`avg`/`last` | field skipped |
| field with `weights`: object of numbers → `Weights`, `ItemAgg = null` | otherwise skipped |
| field without `weights`: `item_agg` not `sum`/`avg`/`last` | field skipped (no default) |
| `label` missing | key humanized: `_` → space, first letter upper-cased; a trailing `_g`/`_lbs` token is dropped |
| `unit` missing | `""` |
| `unit_position` exactly `prefix` | `UnitPrefix = true`, else `false` |
| `split`, `hidden` not a JSON boolean | `false` |

**New method:** `GetReportSeriesAsync(string workflowId, DateOnly from, DateOnly to, string tz)`:
POST `/rest/v1/rpc/report_series`, same pattern as `SearchItemsAsync`. Dates go out as
`yyyy-MM-dd`. `field_values` entries are read as doubles, `field_counts` as ints, `field_shares`
as nested `{string: double}`; any entry that isn't the expected JSON type is skipped.

**Comment-only change on `GetItemEventsAsync`** (no callers today): since `20261115000000`,
`item.stage_changed` events carry `data = {"cleared": {...}}`, so any future replay of events to
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

static DateOnly AddPeriods(string period, DateOnly p, int n) => period switch
{
    "day"   => p.AddDays(n),
    "week"  => p.AddDays(7 * n),
    "month" => p.AddMonths(n),
    _ => p.AddDays(n),
};
```

**Focused period and range.**
- `current = PeriodStart(period, today)`. The **focused** period `F` starts at `current`.
- A stepper `‹ This week ›` moves `F` back/forward one period; `›` is disabled when `F == current`.
  Label: "This week" when `F == current`, else "Week of Nov 2" (`day`: "Nov 2"; `month`:
  "November 2026").
- Trend-length chips, N = number of periods ending at `F`:

  | period | chips (N) | default |
  |---|---|---|
  | `day` | 7 / 30 / 90 | 7 |
  | `week` | 8 / 26 / 52 | 8 |
  | `month` | 6 / 12 / 24 | 6 |

- Fetch range: `from = AddPeriods(period, F, -(N-1))`; `to = min(NextPeriod(period, F).AddDays(-1), today)`.
  (If the user picks A.1's alternative, `to` becomes `yesterday` when `F == current`.)
  `from` is always a period start, so the server never cuts a period in half.

**Load sequence:**
1. `GetWorkflowAsync`. If `Report` is null, show "This workflow has no report configured." and a
   back link.
2. `tz = await JS.InvokeAsync<string>("getTimeZone")`; on exception, `"UTC"`.
3. `today = DateOnly.FromDateTime(DateTime.Now)` (WASM uses the browser's zone).
4. Compute `from`/`to`; call `GetReportSeriesAsync`. Re-run steps 4 on stepper or chip change.
5. Build the period list: `p = from; while (p <= to) { yield p; p = NextPeriod(period, p); }`
   (exactly N entries). Join to rows on `PeriodStart`. **A missing period, or a missing key in a
   present period, means "no data" (shown as —), not 0.**

**Rendering.** Single column, phone-first, top to bottom. "Focused row" = the row for `F`.
- **Header:** back link `← {ItemLabelPlural}` to `workflow/{WorkflowId}`; `ThemeToggleButton`;
  `<h1>{workflow.Name} report</h1>`.
- **Stepper** and **trend-length chips** (selected chip `ButtonAppearance.Primary`).
- **Count card** (when `ShowCount`): title `CountLabel ?? ItemLabelPlural` ("Days included"), value
  = focused row's `ItemCount` (0 if no row). Rendered first, because it's the context for every
  average below it. Trend: bars of `ItemCount` per period.
- **One `FluentCard` per non-hidden field, in config order:**
  - **Value line:** label, then the focused row's value with unit ("1,850 kcal", "179.5 lbs",
    "7 g"), or "—".
  - **Basis line** from `PeriodAgg` and `Counts[key]`, with `noun = ItemNoun ?? item_label`:
    - `avg` → "avg per {noun} · {n} {noun}s" (e.g. "avg per day · 5 days"). Pluralization is a
      naive `+ "s"`; acceptable for "day".
    - `sum` → "total · {n} {noun}s"; `last` → "latest".
  - **Split block** (derived field with `Split`): one horizontal stacked bar of plain divs, 12px
    high, `border-radius:var(--app-radius)`, one segment per component in `Weights` order, width =
    `Shares[key][comp] × 100%`. Segment colours: `var(--app-accent)`,
    `var(--colorPaletteGreenForeground1, #107c10)`, `var(--colorPaletteMarigoldForeground1, #c19c00)`.
    Below it, one legend line per component (so colour isn't the only cue), using the component's
    own `ReportField` for label and unit: "Protein 45% · 43.8 g". The grams are
    `Values[comp]` (the hidden field's period value); "—" if absent. (If A.4 picks (a), the grams
    become `Values[key] × Shares[key][comp] / Weights[comp]` instead, and (b) adds a
    completeness caption. See A.4.) Percentages are
    `Math.Round(share × 100)`; they may sum to 99 or 101, which is acceptable and not
    "corrected". No split block if `Shares[key]` is absent (no calories that period).
  - **Trend:** inline `<svg viewBox="0 0 {N*10} 80" preserveAspectRatio="none">`, width 100%,
    height 80px. `PeriodAgg == "sum"` → bars; `avg`/`last` → points joined by a polyline (levels,
    not amounts), `stroke:var(--app-accent)`. Periods without data are gaps. Scale: 0 to max over
    the range for bars; min..max with 5% padding for lines (so a weight trend of 178–181 isn't a
    flat line at the top). If there's no data, draw only the baseline. The current (partial)
    period's mark is `opacity:0.5`. Each mark gets a `<title>` with the period label and value.
    No goal line (goals removed).
- **Period list:** collapsed behind "Show each week" ("day"/"month"), newest first, visible fields
  only: `Week of Nov 9 — Calories 1,850 kcal · Weight 179.5 lbs · Fiber 7 g · Sugar 11.5 g`, plus
  `· {count} {noun}s` when `ShowCount`.

**Number formatting.** Invariant culture throughout. Values `0.#`; `kcal` uses `N0`; a
`$`-prefixed value uses `N0` when whole and `N2` otherwise.

**Removed from `final-plan.md`'s page:** the goal block and progress bar, `Fraction`, `GoalFor`,
the goal step line on the trend, the "Set goal" form, and the "Previous N periods" summary with
"Goal met on N of M".

### Step 7. Mechanic dry run (self-rolling-back `DO` block)

Save as `scripts/report_mechanic_dry_run.sql`; run with
`supabase db query --linked -f scripts/report_mechanic_dry_run.sql`. Expected output: an error
starting with `DRY RUN (rolled back):`, followed by the weekly rows.

```sql
do $$
declare v_mech uuid; v_rows jsonb;
begin
  select id into v_mech from public.workflows where name = 'Joe''s Auto Repair';
  update public.workflows set report_config = '{
    "period": "week", "show_count": true,
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

`item_agg: last` because a job's amount is one value, not a running total across stages (and the
mechanic never clears keys, so each job has exactly one segment per field anyway — `sum` would give
the same answer). What to expect: every `period_start` is a Monday; `item_count` matches the jobs
created that week; the week of the job holding 300/500 shows `invoice_amount` 500 and
`estimate_amount` 300; `field_counts` shows how many jobs had each amount; `field_shares` is `{}`.
This is the only check of `period_agg: sum` on real data. It is not a commitment to a mechanic
config.

### Step 8. Build, commit, deploy, phone checks

1. `cd /home/mmcbride/micah/claude/workflow-app/web && dotnet build`.
2. **Only after Step 4a matches, Step 4b prints `PASS` and Step 7 prints the expected rows**, make
   one commit containing: the two migrations; both `scripts/*.sql` files; the client changes; both
   pages; `timezone.js` and the `index.html` change. The message explains snapshot-on-clear, the
   per-stage dedupe, and the two aggregation levels. Do not commit `plans/diet-workflow/test-plate.jpg`.
3. **With the user's go-ahead**, push to `main` (triggers `deploy-pages.yml`). Confirm the deploy
   succeeded.
4. On the phone:
   1. **Nutrition list.** A "Report" link appears. The mechanic and Feature Pipeline lists have none.
   2. **Report page, this week.** Cards in order: Days included, Calories (with split), Weight,
      Fiber, Sugar. No Protein/Carbs/Fat cards. Numbers match Step 4a. The split's three
      percentages sum to ~100 and its gram figures match 4a's protein/carbs/fat averages (with
      A.4 option (a), they match `calories × share / weight` instead).
      If the page gets a 404/PGRST202 on `rpc/report_series`, apply the PostgREST-reload fallback
      in Section 4.
   3. **Stepper and chips.** `‹` to last week shows "Week of Nov 2" with "—" everywhere (no data);
      `›` returns; `›` is disabled on this week. 26-week chip: trend has 26 slots, the last faded.
   4. **Real forward-move path with a correction.** On today's item: enter Breakfast values,
      Complete Stage to Brunch, enter Brunch values → today's contribution is breakfast + brunch
      (check via the period list or by the week average moving by the expected amount). Move back
      to Breakfast, correct a value, move forward again, re-enter Brunch (the forward move clears
      it; existing behaviour) → corrected breakfast + brunch.
   5. **Weight.** Set `weight_lbs` on two different days (one via chat). The Weight card shows their
      average and "· 2 days" (or more, if other days have weigh-ins). Setting weight twice on the
      same day changes the day's value, not the count.
   6. **List label.** The 11-12 evening item reads `… 2026-11-12`.
5. If a phone check fails, fix it in a follow-up commit and re-check.

### Step 9. PROGRESS.md

Per `CLAUDE.md`, `PROGRESS.md` is updated at the next milestone the user asks for, not as an
automatic step. Points to carry into it: the weekly Nutrition report is built, in dev only; add it
to the not-yet-ported-to-prod list; the deferred write-side `move_stage` follow-up (D1 residual);
the outcomes of Decisions A.1 and A.4.

## 4. Assumptions not verified

**`set local role authenticated`, `reset role` and `set_config('request.jwt.claims', …)` work inside a
`DO` block through `supabase db query --linked`.** Verified on the local stack as `postgres`, not
through the Management API.
- Detection: a permission or role error instead of `PASS`/`FAIL`.
- Fallback: the dashboard SQL editor, then Step 8 check 4.

**The CLI's role can update `items.created_at` (4b back-dating).** It owns the table on local; on
dev the Management API runs as `postgres`, which should too.
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

**The Fluent green, marigold and neutral tokens exist in v5.** No fallback needed: the hex values
are deliberate final values.

## 5. Risks and edge cases

- **The fourth redefinition of `move_stage`.** Mitigated by the literal body (Step 1), the Step 4
  diff, and 4b checks 8–9. Rollback: re-apply `20261113000000`'s body as a new migration; old
  events keep their `cleared` data, which is harmless.
- **D1 residual** (backing out without editing). Matches the stage UI; deferred (A.2).
- **Today's partial day lowers the current week's averages** (A.1).
- **Two items created on the same day** count as two "days" and are averaged as two. The list
  shows them as two entries too; one item per day is the workflow's convention, not enforced.
- **A day with only some macros logged** (e.g. protein via chat). It lowers the Calories average
  and skews the split (A.4's table: 385 vs 600 kcal, 45/31/23 vs 30/40/30). How the report handles
  it is **Decision A.4**, still open. Scan Plate always writes all three macros, so these days only
  come from chat. No current dev item is one (re-checked 2026-11-15).
- **Two items with identical `created_at`** under `period_agg: last`: the greater `items.id` wins
  (D9). Deterministic, not meaningful; not exercised by 4b.
- **Values logged onto an older day's item** count toward that item's creation day.
- **Missing fields** show "—", not 0.
- **An unparseable live value** (e.g. the agent writes `"30g"`) makes that stage contribute
  nothing; the stage UI shows the same raw string.
- **Config edits are migrations** and the CHECK rejects malformed shapes outright, so a bad config
  fails the push rather than rendering a broken page.
- **Mechanic revenue would bucket by creation week** (D5) if a mechanic config is ever committed.
- **Prod.** These migrations will go to prod with the 2026-11-12 batch. The `move_stage` change is
  inert for prod's mechanic (no shared keys). The `report_config` update matches by name, so it
  only applies if a "Nutrition Tracker" workflow exists there; porting it is a separate, open
  decision.
- **Rollback.** Revert the web commit. The column is additive (`alter table workflows drop column
  report_config; drop function public.report_series(uuid,date,date,text),
  private.jsonb_numeric(jsonb), private.report_fields_valid(jsonb);` in a new migration). Roll back
  `move_stage` as above.

## 6. Out of scope (deliberate)

- **Goals / targets of any kind** (removed at the user's request).
- Reports for any workflow other than Nutrition Tracker; committing a mechanic `report_config`.
- A day-by-day breakdown inside the weekly view (a `period: "day"` config would give one, later).
- Cross-workflow reports, custom queries, export, saved views, per-user configs.
- Derived fields beyond positive weighted sums (differences like profit, ratios, derived-of-derived).
- Fiber-adjusted calories (fiber at ~2 kcal/g).
- Turnaround metrics and `date_anchor: "terminal"`.
- Agent/chat access to report numbers.
- Backfilling the pre-snapshot test day; back-dating real items.
- Porting to prod.
- A range cap on `report_series` (round-2 S2, rejected: RLS already scopes it, like `search_items`).
- **The write-side `move_stage` change** for backward moves (A.2).

---

## Changes from `round-3-draft.md` (round 3 → round 4)

1. **New Decision A.4**: how partial-macro days count toward Calories and the split. Three options,
   each with its implementation cost; deliberately not picked. D10 step 1, Step 6c's legend, Step 8
   check 2, Step 9 and Section 5 now point to it. The Section 5 risk bullet that used to hold this
   is now a pointer.
2. **D9 `period_agg: last` tie-break** on identical `created_at`: greater `items.id` wins. The RPC's
   `array_agg` order gained `, its.id desc`. Also stated why `item_agg: last` can't tie.
3. **Step 2 Notes**: dropped the unreproducible "24 probes" claim. They now cite the 13 saved check-1
   cases by name, and list the remaining validator branches as verified by reading only, with how to
   add them.
4. **Step 5 parser table**: `count_label` and `item_noun` split into two rows, each with its own
   fallback.
5. **Ground truth refreshed** (not from a review; found while checking A.4 on dev): `8c4775d6` has
   since moved to lunch before Step 1 exists, so it joins `a831e45f` as a day with no snapshots
   (0.1, D2, the Step 1 migration comment). All four items have all three macros.

Nothing else changed. The Step 2 SQL differs from round 3 only by the tie-break's `, its.id desc`,
and the Step 4b script is unchanged. The local-stack run in Section 0.2 used round 3's SQL. The
added order key can't change any 4b result (no check uses `period_agg: last`), but re-run 4b
locally once along with any A.4 change.

## Changes from `final-plan.md` (round 2 → round 3, for reviewers)

1. Goals removed everywhere: `report_goals` (old Step 3), `goal_direction`, D4, goal UI, goal
   client methods, old A.1 (Carbs/Fat direction) and A.4 (goal-in-effect rule).
2. Single `agg` replaced by required `item_agg` + `period_agg` (D9); RPC split into explicit
   level-1/level-2 CTEs.
3. Derived weighted-sum fields added; calories (4/4/9) and the energy-weighted split computed in the
   RPC (D10). RPC returns `field_counts` and `field_shares`.
4. CHECK now validates each field via `private.report_fields_valid` (both aggs required, legacy
   `agg` rejected, derived-field rules, unique keys), NULL-safe like before.
5. Nutrition config: `period: "week"`, all fields `period_agg: "avg"`, weight `item_agg: "last"`,
   `show_count: true` labelled "Days included", protein/carbs/fat hidden as cards.
6. Step 4a rewritten for one weekly row plus a live-data cross-check; 4b rewritten around an
   isolated back-dated test week (the baseline-delta trick doesn't survive averaging), with new
   checks for the week aggregates, calories, shares, counts and week-boundary timezone bucketing.
   Both SQL artifacts were run on the local stack in a rolled-back transaction and passed.
7. UI: stepper for the focused week; count card; split block; line trend for averages; no
   multi-period summary.
8. Round-2 sanity-check finding #6 (avg of avg) is **resolved** by D9, not just documented.
9. New Section A: partial current day (A.1); D1 residual (A.2, carried); commit/push (A.3, carried).

## Feedback from this round (round 3 → round 4)

Input: `round-3-sanity-check.md` and `round-3-review-notes.md`, plus the orchestrator's
instruction to raise the partial-macro question as a user decision without picking an option.

| item | source | outcome |
|---|---|---|
| Partial-macro days lower the Calories average with no signal to the user (finding 1) | sanity-check, must-address | **Adopted** as Decision A.4 with options (a)/(b)/(c) and each one's concrete cost. Not picked: it's the user's call. |
| The same partial days skew the split, 45/31/23 vs 30/40/30 (finding 2) | sanity-check, must-address | **Adopted** within A.4; all three options cover the split along with calories. I re-derived both splits: 700/480/360 of 1540, and 360/480/360 of 1200. **One correction to the finding's premise:** it says breakfast-only dev items are partial-macro days. Dev shows all four items have all three macros. A breakfast-only day is incomplete in time (A.1), which A.4's options don't affect. A.4 says this so the user doesn't expect (a) to fix early-day undercounting. |
| 385-vs-595 is real; same root cause (finding 3) | sanity-check, verification | **Noted.** Under A.4(a) it can't arise; D10's per-day choice stands either way. |
| "Days included" can read as the denominator of every card (finding 4) | sanity-check, worth considering | **Not adopted this round.** Every card already shows its own "· n days", and the orchestrator scoped this round to the two must-address findings and the three review notes. Worth raising with the user alongside A.4 if they want the label changed (e.g. "Days tracked"); it's a one-string config change. |
| Atwater-on-fiber, `item_agg`/`period_agg` sufficiency, dedupe re-trace (findings 5–7) | sanity-check | **No change**; they confirm the existing text. |
| `count_label`/`item_noun` fallbacks conflated (note 1) | review | **Adopted**: two rows, explicit fallback each. |
| "24 probes" not reproducible (note 2) | review | **Adopted** by correcting the prose to the 13 saved cases. I didn't add the other 11 to the script: they haven't been run, and the script is described as having passed. How to add them is given in Step 2's notes. |
| `last` tie on identical `created_at` (note 3) | review | **Adopted**: `items.id desc` tie-break, in both D9 and the SQL. |

## Feedback from round 2 → round 3 (kept for history)

That round's input was the user's scope change (relayed by the orchestrator), not reviewer notes.

| item | outcome |
|---|---|
| Remove goals entirely | **Adopted** in full (see Changes 1). |
| Scope to Nutrition weekly report; mechanic dry run only | **Adopted.** Kept `period` configurable (it costs nothing and the CHECK/helpers already exist); only Nutrition gets a config, set to `week`. |
| Calories derived via Atwater; 3-way split excluding fiber/sugar | **Adopted** (D10). Verified the fiber+sugar ⊆ carbs premise in `scan-plate/index.ts`. |
| Weight = weekly average of each day's last value; fiber/sugar = sum within day, average across days | **Adopted** (D9, Nutrition config, 4b check 6). |
| Days included via `show_count` | **Adopted**, plus a `count_label` so the card reads "Days included" rather than "meal dates". |
| Split `agg` into two independent settings | **Adopted** as `item_agg`/`period_agg` (naming justified in D9), both required with no defaults. |
| Average daily calories vs calories from averaged macros: pick one | **Picked per-day-then-average** (D10); identical when days are complete, correct when they aren't; asserted in 4b (385 vs 595). |
| Calories/% in SQL or Blazor: pick one with a new decision ID | **SQL, config-driven** (D10). Numbered D10 rather than D7 because D7/D8 keep their `final-plan.md` meanings. |
| Resolve sanity-check #6 explicitly | **Done** in D9. |
| Keep Step 1, D1 dedupe, D5, NULL-safe CHECK | **Kept**; CHECK extended via a validator function because per-element validation needs a subquery. |
| Carry forward planning-only framing and Section A | **Done**; Section A replaced with the questions still open. |
