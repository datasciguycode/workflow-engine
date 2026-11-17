# Round-3 draft review notes (structure / communication lens)

Reviewed: `plans/generic-report-feature/round-3-draft.md`, cross-checked against
`plans/generic-report-feature/final-plan.md`, `CLAUDE.md`, `PROGRESS.md`, and the live repo
(`supabase/migrations/`, `web/Services/WorkflowApiClient.cs`).

## Overall

This is an unusually tightly cross-referenced draft. The tombstones for removed material (D4,
Step 3) are explicit and consistent with what `final-plan.md` actually contained (confirmed by
grep: `report_goals`, `goal_direction`, `GetReportGoalsAsync`/`AddReportGoalAsync` only appear in
round-3 inside sentences that say they were removed — no stray leftover references). The two new
decisions (D9 `item_agg`/`period_agg`, D10 calories/split) are each specified with a concrete
table of semantics, a rejected-alternatives list, and are traced through the migration comment,
the RPC's CTEs, the shipped Nutrition config, and the Step 4b test's expected-values table. The
"Changes from final-plan.md" and "Feedback from this round" tables at the end let a reader
reconcile every round-2→round-3 change against this draft's own sections. I did not find any
place where a later step silently contradicts or undoes an earlier one, or where a named
file/function/config key fails to match across sections (verified `20261113000000`'s filename
against the actual migrations directory, `WorkflowSummary`'s current 3-arg signature against the
actual source file, and the Nutrition config's field order against the Step 8 phone-check's
expected card order — all consistent).

Specific answers to the five things I was asked to check:

- **Two-aggregation design (`item_agg`/`period_agg`).** Spelled out precisely enough to implement
  without guessing: D3's table states which is required/absent per field type, D9 gives the exact
  per-level semantics (null-handling, tie rule for `last`), the migration comment restates it for
  whoever reads the SQL file in isolation, and the CHECK validator (and its 13 live test configs in
  Step 4b, section "1. CHECK constraint") enforce every rule stated in prose. No defaulting
  anywhere, matching the stated intent.
- **Calories/% split.** D10 gives the exact formula (weighted sum over non-null components,
  average-of-per-day rather than derive-from-averaged-grams, energy-weighted shares), and the RPC
  SQL implements it in named CTEs (`derived_terms`/`item_terms`/`item_vals`/`period_vals`/
  `period_terms`/`period_shares`) that map 1:1 onto D10's three numbered steps. Partial weeks:
  explicitly handled (`item_count` includes empty days; "Days included" is separate from any
  field's own count). Missing fields: explicitly "left out of that average, not counted as 0"
  (D9's bullet under "Decided in this plan"), with `field_counts` as the visible denominator.
- **Removed sections.** D4 and Step 3 are one-line, unambiguous tombstones, not silent gaps. Good.
- **Section A.** Matches what's actually still open: A.1 is new (today's partial day — replaces
  the now-moot old A.1 goal-direction question), A.2/A.3 are carried over unchanged and still real
  (the D1 residual and commit/push sequencing have nothing to do with goals). I didn't find an
  open question that's missing from Section A, nor an item in Section A that's actually already
  fully resolved elsewhere in the doc.
- **Leftover references to removed concepts.** None found by grep (`goal_direction`,
  `report_goals`, bare `"agg"`) — every hit is either inside a sentence saying "removed," inside a
  rejected-alternative note, or inside a Step-4b test case deliberately constructing the old shape
  to assert the CHECK now rejects it.
- **Step 4b.** Concrete and runnable as written: a single self-contained, always-rolling-back `DO
  $$ … $$` block, saved to a named file, run with a given CLI invocation, with a stated
  pass/fail signal (`PASS` vs. anything else) and a worked-by-hand table showing where each
  expected number in check 6 comes from. This is executable by someone with no more context than
  the document.

## Issues found

All are minor; none individually rise to "needs another draft." Listed roughly in order of how
much they could trip up a cold implementer.

1. **Parser-table row conflates two properties' fallbacks (Step 5, "`ParseReportConfig` rules"
   table).** The row

   > `count_label` / `item_noun` missing or not a string → `null` (page falls back to
   > `ItemLabelPlural` / `item_label`)

   packs two different properties and two different fallback targets into one row, relying on the
   reader matching them up positionally ("`count_label`" → "`ItemLabelPlural`", "`item_noun`" →
   "`item_label`") rather than stating each pairing on its own line. It's recoverable — D3's
   earlier table already states each default individually ("`count_label` ... default
   `"{ItemLabelPlural}"`", "`item_noun` ... default the workflow's `item_label`") — but the Step 5
   table is the one place that's wrong on a quick skim, since it reads as if both properties fall
   back to the same pair of values rather than one each.

2. **"24 probes" claim in Step 2's Notes isn't a reproducible artifact.** Step 2's post-migration
   Notes say `report_fields_valid` was "verified... against 24 probes, all as expected," and lists
   the categories of rejected input in prose. Step 4b's actual, saved, re-runnable script only
   exercises 13 configs against the live CHECK (not 24 probes directly against the function). An
   implementer who wants to confirm the "24 probes" claim, or re-run it, has no script to do so —
   only a category summary to take on faith. This doesn't block execution (Step 4b's 13 cases are
   independently sufficient and are reproducible), but the draft asserts verification work that it
   doesn't hand over as something the next person can rerun, which is a small completeness gap
   given how carefully everything else in this draft is made reproducible.

3. **Minor, not-fully-specified edge case: `last` tie-break on identical `created_at`.** D9 says
   `period_agg: last` "takes the non-null value of the latest-created item," and the RPC orders by
   `its.created_at desc`. Section 0.1 notes `item_events.seq` never ties (an events-table fact),
   but says nothing about two *items* sharing the same `created_at` — which is possible in
   principle (e.g., two items created back-to-back) even if it hasn't happened in the dev data
   shown. This is a genuine (if narrow) ambiguity in what "latest" means if it ever ties, not
   covered by any check. Flagging for completeness since it's close to my lens (an implementer
   hitting a tie in Postgres gets an arbitrary-but-stable row via `array_agg(... order by
   created_at desc)`, which is a silent, undocumented choice).

## Verdict

No contradictions, no scrubbing misses, no step that's impossible to execute without guessing.
The two things I was most asked to scrutinize — the two-aggregation-setting redesign and the
calories/% computation — are each specified completely enough (formula, SQL shape, partial/
missing-data behavior) that someone with only this document could implement them without having
to invent anything. The three issues above are all polish-level: worth a quick fix before or
during implementation, but none of them require a fourth draft. **Ready to advance** (pending
whatever the independent sanity-check pass turns up on the technical-correctness side, which is
out of scope for this review).
