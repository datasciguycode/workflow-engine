# Round-1 review notes: structure, completeness, executability

Reviewed against: `CLAUDE.md`, `PROGRESS.md`, `supabase/migrations/20261115010000_add_workflow_report_config.sql`,
`supabase/migrations/20261112000000_add_nutrition_tracker_workflow.sql`, `supabase/migrations/20261119000000_add_closed_at_field.sql`,
`web/Pages/WorkflowDetail.razor`, `web/Services/WorkflowApiClient.cs`, `supabase/functions/scan-plate/index.ts`,
`supabase/config.toml`, `scripts/report_series_dev_check.sql`.

This is a review of the plan's structure as a hand-off document — not a check of whether the
tax/engine/privacy reasoning is correct (that's the sanity-check agent's lane). Where a step
looked simply wrong, I noted it in passing but didn't chase it.

## Issues

1. **Step 6e (`_usd` prefix rendering) never updates the actual rendering call site, and the
   plan's own stated result is inconsistent with the code it points to.** §1's codebase facts say
   `FieldUnitSuffixes` is a `(string Suffix, string Unit)[]` and is consumed at the merged-field-
   line in `WorkflowDetail.razor` via the literal `$"{FieldText(field, v)}{unit} {baseLabel}{star}"`
   (confirmed at `web/Pages/WorkflowDetail.razor` lines ~89-91) — i.e. the unit is always glued
   *after* the value, hardcoded at the call site, not inside `FieldLabelAndUnit`. Step 6e says to
   add a `prefix: true` flag to the table and have `FieldLabelAndUnit` "return a prefix/suffix
   flag," and claims the visible effect is `$12.50 Tolls`. But it never says the call site itself
   (the `@($"{FieldText(field, v)}{unit} {baseLabel}{star}")` branch) must branch on that new flag
   to put `unit` before `FieldText(...)` instead of after. Without that edit, the described output
   can't happen — a reader who implements only what's written will get `12.50$ Tolls`. This is a
   real gap: a step is implied (the call site must change) but never stated, and the one line that
   *is* given reads as a guarantee that doesn't match the referenced code.

2. **Step 6d is underspecified: whose "same local date" is compared, and by what identity.** "For
   non-job workflows, append the local time `HH:mm` when another loaded item has the same local
   date" doesn't say whether "another loaded item" means every item in `_items` regardless of
   workflow/stage, or only items in the same stage as the one being named (`StageTitle` is part of
   the display string, so two items in different stages on the same day presumably don't collide
   and arguably shouldn't both get the suffix). It also doesn't say whether the comparison is
   computed once per render pass (e.g., precomputing a set of "dates with duplicates" ) or per-call
   inside `ItemDisplayName`, which matters for where the diff would need to be implemented given
   `ItemDisplayName` is currently a simple pure-ish helper. An implementer has to guess the grouping
   key.

3. **Step 0's precondition is a blocking unanswered question, but the plan's own later steps are
   written as if it resolves cleanly.** Step 0.1 says "Don't push without that answer" about the
   untracked `20261119000000_add_closed_at_field.sql`, and gives two options (push-and-commit it
   first, or move it aside) without picking one or saying what changes downstream if the user picks
   "move it aside" (e.g., would it need its own later timestamp once restored, does it affect the
   `db push --dry-run` expectation text in Step 4, which just says "expect only the expected files
   (see Step 0...)" without stating what the expected file list actually is under each branch).
   This is fine as a genuine open question to raise with the user, but as a hand-off document it
   leaves Step 4's dry-run verification criterion implicit rather than spelled out for either
   branch.

4. **Step 1a's SQL comment claims behavior it doesn't fully state the consequence of.** The comment
   says "Why the old `> 0` rule doesn't need to survive: negative weights only change the
   arithmetic of `sum(weight * value)`," but the CHECK code shown also silently drops the
   `item_terms_all`/`item_terms` "every component present" requirement discussion — that part is
   unchanged and still correctly described elsewhere (§1e rejected-alternatives), so this isn't a
   contradiction, just noting the plan leans on the reader cross-referencing two sections to
   confirm nothing else about derived-field semantics shifted. Not a blocking issue, just a
   completeness note: a one-line pointer ("see §1e for why derived-field null semantics are
   unaffected") would remove the need to cross-check.

5. **Step 2's stage-insert for "Rideshare Mileage" uses `on conflict (workflow_id, title) do
   nothing`, matching the Nutrition precedent — but the plan never confirms, the way it did for the
   `workflows.name` uniqueness gap, that a `(workflow_id, title)` unique constraint actually exists
   on `stages`.** It happens to (confirmed independently: `stages_one_initial_per_workflow` and
   related indexes exist, and Nutrition's migration already relies on this same conflict target
   successfully), but the plan's own stated discipline in §1 ("workflows.name has no unique
   constraint... this plan uses `where not exists` instead") makes its silence on the stages
   constraint read like an oversight rather than a verified fact, since it explicitly flagged the
   analogous gap for `workflows` but not for `stages`. A reader without outside access to the
   migrations directory has no way to confirm this constraint exists from the plan text alone.

6. **Step 6f's capture flow (point 5, "Build the patch") doesn't say what happens to `{prefix}_area`
   when the async `GetAreaAsync` task (started in point 2, "concurrently") hasn't resolved by the
   time the scan result and plausibility checks finish.** Is the area write deferred (an `await
   areaTask` is implied right before building the patch) or fire-and-forget (patched in later via a
   second `UpdateDataAsync` once it resolves)? The ordering between "scan returns" and "area
   resolves" isn't fixed (reverse-geocode has its own 5s timeout per §5b, scan-odometer has no
   stated timeout), so a reader has to guess whether point 5 waits on point 2's task or not.

7. **Step 6f, plausibility check 4's "against the latest `end_odometer` among other `_items`,
   ordered by `end_time`" doesn't say how this data is fetched.** Elsewhere the plan is careful to
   name exact RPCs/endpoints (`UpdateDataAsync`, `ReverseGeocodeAsync`, `search_items`), but this
   check implies either a new query/RPC or a client-side scan of an already-loaded `_items` list
   (which may not be fully loaded if "Show closed" is off per the existing `VisibleItems()` filter
   Step 6c is simultaneously changing) — no function name or data source is given, so an
   implementer must invent one.

8. **Rollback section's "Content" rollback step doesn't account for cross-reference to Step 6c's
   list-visibility rule or the fact that items for these two workflows would already be shown
   on-screen during any partial rollback window.** This is a minor completeness gap, not a
   correctness one: the rollback section is the right level of detail for the engine and functions,
   but the "delete item_events, then items, stages, workflows, matched by name" step gives no SQL,
   unlike the rest of the plan which otherwise always inlines runnable SQL or exact commands. Given
   the plan's own established style (every other step gives literal SQL/bash), this one reads as a
   level less specified than its neighbors — worth flagging for consistency even though the general
   shape is clear enough to execute by someone already fluent in the schema.

## What's solid (for context, not exhaustive)

- Step 1's SQL diffs are concrete, inline, and each change is marked (`-- NEW`, `-- CHANGED`)
  against the real prior migration, which I verified matches `20261115010000_add_workflow_report_config.sql`
  line for line where it claims to.
- The `workflows.name` no-unique-constraint fact and the resulting `where not exists` pattern in
  Step 2 is both correctly identified and correctly worked around, in contrast to issue 5 above
  regarding `stages`.
- Deploy commands (Step 4 migrations, Step 5d functions) match this repo's established
  conventions exactly (`--project-ref`, `--use-api`, naming the function explicitly, `--dry-run`
  before a real push) — consistent with `scan-plate`/`scan-vin` precedent and PROGRESS.md's
  descriptions of prior migrations.
- `IsClosed` in Step 6c correctly uses the real `StageSummary.Checklist`/`OptionalChecklist`
  (`List<string>`) shape from `WorkflowApiClient.cs`, and its effect on each of the three existing
  workflows (mechanic, Nutrition, and the two new ones) is worked through explicitly and correctly
  predicts current behavior is unchanged for the first two.
- `move_stage`'s "Shift's start_*/end_* keys aren't shared" claim (§1) is correct — I independently
  confirmed the two stages' checklists share no keys, so §1's claim that no snapshot logic is
  needed for this workflow holds given `20261116000000`'s actual "shared key" definition.
- Content-migration matching-by-title convention, `security invoker`, and RLS reliance on
  `items_select`/`workflows` policies are all correctly carried over with no changes needed, and
  the plan correctly doesn't introduce any new RLS policy since nothing new touches ownership.

## Verdict

Seven real gaps (issues 1–7) plus one minor style-consistency note (issue 8). None of them are
"cannot be executed at all" — a sufficiently senior engineer could infer reasonable answers for
most (especially 2, 6, 7) — but issue 1 is the most serious: it's not just unspecified, the plan's
stated outcome (`$12.50 Tolls`) will not occur from the stated edit, which is the kind of
quiet contradiction between a claim and the referenced code that should be caught before this
is handed to someone who takes the doc at face value. Issue 3 (the Step 0 open question) is also
worth tightening before build, since it gates the very first executable step and the plan doesn't
commit to an answer or spell out the two downstream branches.

Recommend one more revision round focused narrowly on: (a) fixing/completing Step 6e's rendering
call-site edit, (b) resolving or explicitly branching Step 0's precondition, and (c) tightening
Steps 6d/6f/7's underspecified mechanics (issues 2, 6, 7). The rest of the document is unusually
well-sourced and precise (exact SQL diffs, exact line references, correctly verified codebase
facts) and would not need a fresh pass once those are patched.
