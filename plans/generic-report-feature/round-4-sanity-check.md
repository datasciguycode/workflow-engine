# Round-4 sanity check: `plans/generic-report-feature/round-4-draft.md`

Scope per the task: (1) verify the dev-data claim behind Decision A.4, (2) assess whether
A.4's three-option framing is complete/correctly reasoned, (3) check whether this round's
targeted fixes (the `period_agg: last` tie-break, the probe-count correction, the
`count_label`/`item_noun` fallback-table split) hold up or introduced/revealed anything new,
(4) flag anything else new in this round. Round-3-unchanged content is not re-litigated.

## Verdict

**No plan-blocking issues.** This round's targeted fixes hold up under hand-trace and direct
verification. The dev-data claim behind A.4 is true and accurately stated. The findings below
are all "worth considering" — none of them is a correctness bug in what's about to be pushed,
and none should by itself trigger another full round. The one item I'd actually want closed out
before Step 4 (not another round, just a one-line addition to this draft or to the orchestrator's
go-ahead checklist) is the first finding: making sure A.4 doesn't resolve itself by default.

## Findings (most to least significant)

### 1. (process / critique) A.4 risks silently resolving to option (c) by default — the exact failure mode the rest of the plan is built to avoid

A.4 is deliberately left unpicked, and Step 2's SQL as currently written implements the
*current* behavior (partial days counted as-is) — i.e., it already *is* option (c) unless and
until the user says otherwise. The draft only says "if you choose (a) or (b), ... re-run before
Step 4"; it never says what happens if the user approves the overall plan without explicitly
addressing A.4. In practice, that silence resolves to (c) by default, with no CHECK, no
migration content, and no explicit record forcing a conscious choice.

This is notable because D9 exists specifically to kill silent per-field defaults
("a silently defaulted level is exactly the bug class being fixed... every field states both,
and the CHECK enforces it"). A.4 is the one place in this draft where a consequential behavior
(whether partial-macro days quietly bias Calories/%) can still default into place without an
explicit, recorded user decision enforcing it the way the CHECK enforces `item_agg`/`period_agg`.

**Fix:** before Step 4's push, require an explicit answer to A.4 — even "(c), on purpose" counts
— captured the same way the "Decided in this plan" bullets are, not left to be inferred from an
unqualified "approved."

### 2. (alternative) The three A.4 options bundle Calories and the split together; a 4th, asymmetric option is missing and may be better

All three options treat "how a partial day counts toward Calories" and "how it counts toward the
split" identically. But the two numbers are not equally distorted by a partial day: Calories is
only biased in magnitude (a protein-only day undercounts its calories, pulling the average down
somewhat), while the split's percentages are biased in *kind* — a protein-only day's "100%
protein" share gets averaged in at full weight next to genuinely mixed days, which is a much
larger distortion per affected day (visible in A.4's own numbers: the split moves from 30/40/30
to 45/31/23, a 15-point swing, while Calories moves 385→600, a ~1.5x swing in absolute terms but
built from fewer, noisier inputs for the split specifically).

A worth-naming 4th option: **exclude partial days from the split's shares only, keep them in the
Calories average.** Rationale: partial logged intake is still real signal for "how many calories
did I eat," just an undercount, whereas it's actively misleading for "what fraction was protein."
This keeps more data in the number users probably care about most (today's/this week's calorie
total) while still fixing the specific distortion the original sanity-check findings 1 and 2
called out for the split. Concretely: `period_shares` already computes over exactly the
`item_terms` that fed step 2's per-item calories (D10 step 3 says "over exactly the same items as
step 2"); decoupling it would mean computing `period_shares` over only-complete-day `item_terms`
while still letting step 1/2's per-item/per-period calories include partial-day contributions as
today. That's a smaller, more surgical change than option (a)'s full exclusion, and avoids (b)'s
added UI surface for a number (Calories) that arguably doesn't need a caveat as badly as the
split does.

This doesn't have to be adopted — (a)/(b)/(c) all work — but it's a real point in the design
space that the "pick one of three" framing didn't surface for the user.

### 3. (critique) Option (a)'s implementation is a non-configurable, permanent policy for *every* derived field, not just today's `calories`

Option (a)'s SQL change ("only items that have every component of the derived field") is
explicitly framed as "the rule for all derived fields, with no config property," on the grounds
that "a weighted sum missing some of its terms is unreliable for any workflow." That's a
reasonable call for `calories`, but it's a bigger decision than A.4's framing suggests: it's
being made once, for every derived field the engine will ever have, with no way to opt out later.
A future derived field where partial sums *are* meaningful (e.g. a "profit" field — mentioned
elsewhere in this same draft as a plausible future derived field under "Known approximation" /
"Constraints, deliberately narrow" — where you might reasonably want `estimate_amount -
invoice_amount` from whichever side is logged) would silently inherit this all-or-nothing rule
with no CHECK-enforced way to say otherwise, which is exactly the kind of implicit, workflow-wide
default the rest of this plan goes out of its way to avoid (D9's whole justification for
splitting `agg` into two required, no-default properties).

Not a reason to reject (a) — just worth a one-line acknowledgment in D10/A.4 that choosing (a)
is also choosing this precedent for every derived field going forward, the same way D9 calls out
its own precedent-setting.

### 4. (critique) The CHECK-constraint validator (`report_fields_valid`) is the only safety net for `report_config` and most of its branches are untested, by the draft's own admission

Step 2's notes are honest about this ("Other validator branches are correct by reading the SQL,
not by any saved test") — that honesty is itself a strength of this round (see finding on the
probe-count fix below), but the underlying gap is real: of the function's branches, only 13 are
exercised by the saved script; at least 11 more (JSON-null agg, non-string/missing `key`, scalar
array element, null/array/empty `weights`, zero weight, unknown component, and the duplicate-key
counting path under some of those) are verified only by reading nested `CASE`/`coalesce`/
`bool_and` SQL. I read through the function myself and didn't find a bug in it, but that's a
weaker guarantee than an executed test, and this function gates a database CHECK — the mechanism
this whole plan relies on to make a bad config fail the migration push rather than corrupt a
report at read time (Section 5: "Config edits are migrations and the CHECK rejects malformed
shapes outright, so a bad config fails the push rather than rendering a broken page"). That
guarantee is only as strong as the validator actually is.

**Fix:** add the 11 additional cases to `scripts/report_series_dev_check.sql`'s check-1 array
before Step 4 — the draft already gives the exact JSON literals to add (Step 2 notes) and says
"re-run it there before relying on it." Do that now rather than leaving it as a documented gap
for whoever next edits this function.

### 5. (minor / implementation gap) `ItemLabelPlural` is assumed available to the new page but is currently private to `WorkflowDetail.razor`

Step 6c's header ("back link ← `{ItemLabelPlural}`") and Step 5's parser-table fallback ("the
count card's title falls back to the workflow's `ItemLabelPlural`") both reference
`ItemLabelPlural` as if it's a property the new `WorkflowReport.razor` page can just use. In the
current codebase it's a private computed property inside `WorkflowDetail.razor`
(`ItemLabelSingular + "s"`, `web/Pages/WorkflowDetail.razor:480`), not shared. This is a one-line
fix (duplicate the same naive `+"s"` computation in the new page, which is consistent with how
the rest of this draft already treats pluralization as "naive, acceptable for 'day'"), but Steps
5/6c don't call out that this small bit of logic needs to be written twice. Worth a one-line
note so whoever implements this doesn't go looking for a shared helper that doesn't exist, or
worse, silently diverges in behavior between the two pages.

### 6. (minor / edge case) Negative values silently zero out a period's split rather than being rejected or flagged

`private.jsonb_numeric` accepts negative numbers (its regex is `^-?\d+(\.\d+)?$`), and nothing
in the write path rejects a negative macro value coming from a chat correction (e.g. a typo
"-5" for protein). `period_shares` only emits a row `where pt.total > 0`, so a period whose
summed weighted energy comes out to zero or negative (plausible if, say, a negative value
partially cancels positive ones across days) silently drops the split for that period instead of
surfacing anything odd. Very unlikely to occur in practice and not worth blocking on, but if it's
cheap, a `where (w.value #>> '{}')::numeric <= 0 then false` sibling check against negative
*logged values* (not just weights, which are already positive-only) in `jsonb_numeric` or
`update_data` would close it.

## This round's targeted fixes — verification results

I verified these three directly rather than taking the draft's word for them:

- **Dev-data claim behind A.4** ("all four current Nutrition items have all three macros,
  including the ones still at an early stage"). **Verified true and accurately stated.** I ran a
  read-only query against the actual linked dev project
  (`utwyvtbzesswpoihmlic`/`contractor-tracker-pilot`) and confirmed all four Nutrition items
  (`a831e45f`, `b173bc11`, `fdd1665e`, `8c4775d6`) carry non-null `protein_g`/`carbs_g`/`fat_g`
  in `item.data` right now. I also independently confirmed dev's migration history stops at
  `20261113000000` (matching the draft's claim that the snapshot migration hasn't been applied
  yet) and that `8c4775d6`'s `item.stage_changed` events have `data = null` (matching D2's claim
  that it has no snapshot and will report only its live stage's values). The draft does not
  overstate this — it correctly scopes the claim to "today's data," not to the write path in
  general, and correctly distinguishes this (A.1, time-incompleteness) from A.4 (macro-field
  incompleteness).

- **`period_agg: last` tie-break** (`order by its.created_at desc, its.id desc`, greater
  `items.id` wins on identical `created_at`). Holds up: `item_agg: last`'s separate claim that it
  "needs no tie-break" is correct, because `item_events.seq` is a verified global bigserial
  (confirmed in Section 0.1's own "ground truth" facts) and the live segment's sentinel seq can
  appear at most once per `(item, key)` since an item has exactly one current stage — so there's
  no tie to break at that level. At the period level, two items *can* share `created_at` (the
  draft's own example: two items created in one transaction share `now()`), so a tie-break is
  actually needed there and the fix is sound and deterministic. Not exercised by 4b (acknowledged
  in the draft), which is fine for something this low-stakes and arbitrary-by-design.

- **Probe-count correction** (dropping the unreproducible "24 probes" claim, naming the 13 saved
  check-1 cases instead). I counted the `foreach c in array array[...]` literal in Step 4b's
  script by hand: exactly 13 entries, matching the corrected claim. This is a straightforward,
  verified fix — no new problem introduced by making the claim more honest. (The remaining
  concern is the one in finding 4 above: honesty about what's *not* tested doesn't close the
  testing gap itself.)

- **`count_label`/`item_noun` fallback-table split** (Step 5's parser table splitting one
  property into two rows with two independent fallbacks: `CountLabel` → workflow's
  `ItemLabelPlural`, `ItemNoun` → workflow's `item_label`). This is consistent with D3's property
  table and with how the two properties are actually used in Step 6c (count-card title vs. the
  "avg per {noun} · {n} {noun}s" basis line) — they really are two different fallback targets, so
  splitting them is correct, not just prettier. No residual issue, aside from the
  `ItemLabelPlural` availability gap noted in finding 5.

I also independently hand-traced 4b's check 2/3/4 (the snapshot-dedupe scenario across a
back-up/correct/forward-skip sequence) and check 6 (the full test-week averages, calories, and
energy-weighted shares) against the SQL. Every number in the draft's "how check 6's expected
numbers come about" table reconciles exactly (protein energy 700, carbs 480, fat 360, of 1540 →
0.4545/0.3117/0.2338; and separately, the A.4 table's 385-vs-600 and D10's 595 "wrong way" example
are two different, both-correct computations over different subsets of the same test data, not a
contradiction). I did not find an arithmetic or logic error in either this round's new SQL or the
carried-over D1/D9/D10 machinery it builds on.

## Summary

- Findings: 1 process/critique (A.4 default risk), 1 alternative (missing asymmetric A.4 option),
  2 critique (option (a)'s unscoped precedent-setting; validator test coverage), 2 minor
  (`ItemLabelPlural` duplication, negative-value edge case in shares).
- Nothing rises to "must address before implementation" in the sense of a bug that would ship
  wrong numbers — the dev-data claim is verified true, and the tie-break/probe-count/fallback-table
  fixes are all technically sound. The closest thing to a must-address item is finding 1: make sure
  A.4 gets an explicit, recorded answer (even "(c) on purpose") rather than resolving by default
  before Step 4's push, since that's the one place this draft could quietly reproduce the exact
  silent-default problem it otherwise polices so carefully.
- This draft is ready to advance; I'd pair it with closing out finding 1 procedurally (not another
  drafting round) before Step 4 runs.
