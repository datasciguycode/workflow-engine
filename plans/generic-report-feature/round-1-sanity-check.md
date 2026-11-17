# Round-1 sanity check: generic Report feature

Independent correctness/feasibility pass (not a clarity review). Ranked most-severe first.

## Must address before implementation

### 1. (Critique) Repeated forward-crossing of the same stage boundary double-counts "sum" fields — and the plan's own worked example is this exact scenario

**What's wrong.** D1's model treats an item's total for field `k` as the sum of every segment that was
ever written to `item.data[k]`: the current live value, plus every `cleared.k` ever recorded on a
`item.stage_changed` event. But `move_stage` writes a **new** `stage_changed` event, with its own
`cleared` snapshot, **every time** a forward move crosses a given stage-pair boundary — including the
second, third, etc. time, if the item was ever moved backward and then forward again across that same
boundary. Nothing dedupes or supersedes the earlier snapshot. The aggregation query (`segments` →
`item_vals`) sums all of them unconditionally for `agg = sum`.

**Concrete scenario** (and it's the plan's own D1 walkthrough, just followed one step further than the
plan takes it): an item progresses Breakfast → Brunch → Lunch normally. This already wrote one
`cleared` snapshot for `protein_g` etc. on the Breakfast→Brunch crossing. The user then — per the
plan's own "backward-then-forward" walkthrough — moves it backward from Lunch to Breakfast (data isn't
cleared on backward moves, so it still holds Lunch's values), edits/corrects the values, and moves
forward again. That second Breakfast→Brunch crossing writes a **second** `stage_changed` event with
its own `cleared.protein_g`. Both events now exist permanently in `item_events`. `report_series` sums
both: the original breakfast values the user ate, *plus* the Lunch-values-relabeled-as-breakfast
correction, as if they were two separate meals. For `sum`-aggregated fields — which is every macro
except weight, i.e. the feature's entire reason for existing — totals are silently inflated whenever a
user backs up and re-crosses a boundary they'd already crossed once. The plan's invariant claim
("every value... counted exactly once") is false in this case; the walkthrough shows the correction
being counted once *for that excursion* but never accounts for the pre-existing snapshot from the
original crossing still sitting in `item_events` and still being summed.

This isn't an exotic edge case for a diet-tracking app — backing up to fix a stage entered in the
wrong order, or re-logging after going back to add a forgotten food, is exactly the kind of correction
a real user will make.

**Fix.** Don't sum every `cleared` event unconditionally. Dedupe cleared segments by
`(item_id, to_stage_id, field_key)`, keeping only the latest (highest `seq`) value per that triple,
before summing across distinct stages. That matches the actual intent: "what was this field's value
the last time the item left this particular stage," not "everything that was ever cleared, including
superseded corrections." This is a change to the `segments`/`item_vals` CTEs in `report_series`, not to
`move_stage` — the append-only write side is fine as designed; only the read-side aggregation needs the
fix. Add a test case to Step 4/8 that does exactly this backward-then-forward-again sequence and checks
the resulting total isn't inflated.

### 2. (Critique) The `workflows_report_config_shape` CHECK constraint doesn't enforce what it claims to

```sql
check (
  report_config is null or (
    report_config->>'period' in ('day', 'week', 'month')
    and jsonb_typeof(report_config->'fields') = 'array'
  )
)
```

Postgres CHECK constraints pass when the expression evaluates to `TRUE` **or `NULL`** — only `FALSE`
fails. If `report_config` is a non-null object missing the `period` key, `report_config->>'period'`
is SQL `NULL`, so `NULL IN (...)` is `NULL`; combined with `AND`/`OR`, the whole expression evaluates to
`NULL`, which **passes**. Same for a missing `fields` key (`report_config->'fields'` is `NULL`,
`jsonb_typeof(NULL)` is `NULL`). So this constraint silently accepts a `report_config` with no `period`
and/or no `fields` at all — exactly the two fields the plan calls "required."

**Concrete consequence.** A `report_config` like `{"period": "day"}` (no `fields`) or
`{"fields": [...]}` (no `period`) passes the constraint. In `report_series`, a missing `period` makes
the `case cfg.c->>'period' when ... end` fall through with no `ELSE`, so every item in range gets
`period_start = NULL` and all collapses into one bogus group; a missing `fields` makes
`jsonb_array_elements(NULL)` yield zero rows silently, so the report renders with zero fields and no
error. Low practical risk today (the one `UPDATE` in this migration sets both keys), but it's a trap for
the next person who edits `report_config` by hand or adds a second workflow's content later, and the
plan explicitly claims this constraint is doing validation it isn't.

**Fix.** Guard with `coalesce`, e.g. `coalesce(report_config->>'period', '') in (...)` and
`report_config ? 'fields' and jsonb_typeof(report_config->'fields') = 'array'`, or require both keys
explicitly with `report_config ?& array['period','fields']`.

## Worth considering (not blocking)

### 3. (Critique) Progress-bar width inverts meaning between `at_least` and `at_most` fields

`width = min(value/target, 1)`, colored green when the goal is met. For `at_least` fields (protein,
fiber), a nearly-full bar means "almost there" (good direction). For `at_most` fields (carbs, fat,
sugar), a nearly-full bar means "almost at the limit" (bad direction, i.e. the opposite visual metaphor
using the identical fill animation). The status line text disambiguates ("Xg to go" vs "Xg over"), so
this isn't broken, but it's a real source of at-a-glance misreading for exactly the fields (sugar, fat)
where misreading matters. Consider a visually distinct treatment for `at_most` fields — e.g. a "budget
remaining" bar that depletes rather than fills, or a different color scale — rather than reusing one
bar metaphor for both directions.

### 4. (Critique) Division-by-zero/NaN edge case in the progress-bar width calc

`min(value/target, 1)` with `target = 0` and `value = 0` is `0/0` → `NaN` in both C#/Razor and
JS/SVG math, and `Math.Min`/`min` comparisons against `NaN` don't behave like a clamp (the result stays
`NaN`, not `0` or `1`). A user plausibly sets an `at_most` goal of `0` for something like added sugar.
Guard this case explicitly (e.g. treat `0/0` as "met, 0 width" rather than relying on the min/clamp to
do it).

### 5. (Alternative) Hand-rolled ISO week stepping duplicates `date_trunc('week', ...)` and risks drifting from it

Step 6 has the client build "the full list of period starts... stepping by period with Monday-start
weeks to match Postgres" by hand. .NET already has `System.Globalization.ISOWeek` (since .NET 6),
which computes ISO week boundaries (Monday-start) directly and is the natural match for Postgres's
`date_trunc('week', ...)` semantics. Use `ISOWeek.ToDateTime`/`ISOWeek.GetWeekOfYear` rather than a
custom stepping loop, to avoid a client/server off-by-one on the week boundary (e.g. around DST
transitions or year boundaries, where hand-rolled "step by 7 days from today" logic is more likely to
diverge from the server's `date_trunc` than a library built specifically for ISO week math).

### 6. (Cut-this, weak) Step 7's mechanic dry run is optional scope, not a blocker

It's clearly marked as not-committed and cheap (rolled back transaction, zero code), and it does serve
as a genuine acceptance test for "generic." I don't think it needs to be cut, but if the goal is to
minimize this round's footprint, it could be deferred to whenever the mechanic report is actually
requested, since nothing in Steps 1–6 depends on it and the user hasn't asked for a mechanic report.
Low-priority; the plan already frames it honestly as a dry run, not a commitment.

## Things I checked that held up

- RLS reasoning: `report_series` as `security invoker` correctly rides on the existing
  `items_select`/`item_events_select`/`stages_select` policies (verified against
  `20261012035437_phase0_core_schema.sql`); no new privilege-escalation surface.
- `report_goals`'s RLS policies and append-only stance match the existing `item_events`/`agent_events`
  precedent.
- The `v_item` pre-update-row capture timing in the `move_stage` rewrite (Step 1) is correct — `v_item`
  is reassigned only by the later `UPDATE ... RETURNING`, so capturing `v_cleared` before it runs
  genuinely reads pre-clear values.
- `jsonb_object_agg` over zero rows returning `NULL` (no cleared keys → `data` stays `null`, preserving
  byte-identical behavior for the mechanic/Feature Pipeline) is correct Postgres behavior.
- The claim that `WorkflowSummary`'s 3-argument positional construction still compiles after adding a
  trailing optional 4th parameter is accurate — confirmed both call sites in
  `WorkflowApiClient.cs` use positional `new WorkflowSummary(id, name, item_label)`.
- `search_items`-style security-invoker RPC pattern, timezone bucketing via
  `created_at at time zone p_tz`, and the overall jsonb-config-on-`workflows` modeling choice (vs. a
  child table) are all sound and consistent with existing precedent in this codebase (`checklist`,
  `optional_checklist`).
- `date_trunc('week', ...)` using Monday-start ISO weeks is correctly stated.

## Verdict

Two findings are severe enough to require fixing before implementation: the double-counting bug (#1)
directly corrupts the feature's core output (daily/weekly macro totals) under a plausible, even
expected, user correction pattern, and should be fixed in the `report_series` aggregation logic before
Step 2 ships. The CHECK constraint bug (#2) is lower practical risk right now but is a real, concrete
SQL defect that should be fixed in the same migration rather than left for later. Neither requires
architectural rework — both are scoped fixes inside the Step 2 migration (the aggregation CTEs and the
check constraint expression) — so the plan's overall shape (write-time snapshot capture, jsonb config on
`workflows`, dated append-only goals, server-side RPC, no new UI deps) does not need to be reworked, but
the plan as currently drafted should not be implemented as-is without addressing #1 at minimum.
