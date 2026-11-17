# Round-3 draft: sanity check (substance/correctness pass)

Scope: independent correctness/feasibility review of `plans/generic-report-feature/round-3-draft.md`
(does not read the parallel plan-reviewer's notes). Verified the draft's own arithmetic by hand
against its Step 4b test data rather than trusting its assertions.

## Verdict up front

No mathematical or SQL-logic bugs found in the RPC, the dedupe/snapshot mechanism, the CHECK
validator, or the 385-vs-595 test case — I re-derived all of it independently and it checks out
exactly as the draft claims (details below). The one real substantive problem is a **product/
correctness judgment call that was made without being raised to the user as a decision**, even
though it directly determines the accuracy of the single most prominent number on the report
(Calories) and the shape of its split chart, and it is not hypothetical — it is already the state
of real dev data today (several of this week's items are partial, breakfast-stage-only). I'd call
this a blocking gap in the *decision record*, not in the SQL: the plan should not proceed to
implementation with this silently decided. Everything else below is "worth considering."

---

## Must address before implementation

### 1. (Critique) Partial-macro days silently bias the headline Calories number downward, and this isn't offered to the user as a decision

**What's wrong.** D10 computes a day's calories from whatever macro components it has logged
(`calories = Σ weight_k × item_value_k` over non-null components), then averages that per-day
figure across days that have *any* of the three. A day where only protein was logged (e.g. a chat
correction, or — per the draft's own Section 0.1 live-data table — any day still sitting at
Breakfast) reports real but structurally incomplete calories: 4×protein only, with carbs and fat
silently treated as "not eaten" rather than "not yet logged." That day is then averaged in
alongside fully-logged days at full weight.

**Why this matters more than the draft's framing suggests.** The draft does flag this ("a day with
only some macros logged ... still gets calories from what's there, and still counts in the
calories average") — but files it as one bullet in Section 5 ("Risks and edge cases"), the same
tier as cosmetic issues like pluralization. It is not offered as a Section A decision alongside
A.1 (today's unfinished day) and A.2 (the D1 residual), even though it's the same *kind* of
judgment call — a tradeoff with a real default the user hasn't been asked to confirm — and it has
a much bigger effect on the number people will actually look at.

**Concretely, using the draft's own Step 4b fixture:** Mon logged protein only (240 kcal from 60g
protein alone); Thu logged protein only (100 kcal from 25g). Tue and Fri are fully logged (500 and
700 kcal). Averaging all four non-empty days gives 385 kcal/day — a number dragged down by two
days whose true calorie intake is *unknown*, not actually ~100-240 kcal. If the week's "average
daily calories" is meant to answer "how many calories do I eat on a typical day," 385 materially
understates it whenever logging is incomplete, and the degree of understatement is invisible from
the Calories card itself (only visible by cross-referencing the basis line's day-count against the
per-field counts, which nothing prompts a user to do).

**Fix / alternatives to put to the user as an actual Section A item:**
- (a) Require all three macro components present for a day to count toward `calories` (and its
  `split`) at all — a day with partial macros contributes to protein/carbs/fat averages
  individually (as it does now) but not to the derived Calories card. Fewer days average in, but
  every day that does is trustworthy.
- (b) Keep the current behavior (partial days contribute partial calories) but surface
  completeness on the card itself (e.g. "385 kcal · 2 of 4 days fully logged") instead of only in
  the basis line's day count, which doesn't distinguish "day had no macros" from "day had some."
- (c) Status quo, but make it an explicit, acknowledged tradeoff in Section A rather than a Section
  5 risk bullet, so the user is actually choosing it rather than inheriting it.

Any of these is defensible; what isn't defensible is deciding it implicitly for a metric this
central.

### 2. (Critique) The same partial-day inclusion distorts the protein/carb/fat split more than the draft's framing acknowledges

**What's wrong.** `field_shares` is an energy-weighted ratio: each component's share of the week's
*total* calories, summed across exactly the items that have a value for the derived field — i.e.
the same partial days from Finding 1 feed into the split's numerator and denominator too. A day
that logged *only* protein contributes 100% of its energy to the protein slice, pulling the
reported split toward protein regardless of what the person's actual macro ratio was that day.

**Concretely, from the same fixture:** the draft's split is protein 45.45% / carbs 31.17% / fat
23.38% (I re-derived this and it's arithmetically correct: 700/1540, 480/1540, 360/1540 kcal). But
restricted to the two *fully logged* days only (Tue: 160/160/180 kcal; Fri: 200/320/180 kcal), the
split is protein 30% / carbs 40% / fat 30% — a materially different macro profile. The reported
45/31/23 split is not "this week's actual protein-heavy eating pattern"; it's an artifact of which
two days happened to log only protein. The stacked-bar chart gives the user no visual cue that this
happened (no indication some wedge of its input is low-confidence).

**Fix:** same remedy set as Finding 1 — either gate `split` on full-macro days the same way as
Calories, or visually flag when the split is built from a day-set that includes partial days.

### 3. (Verification, not a blocking issue — included because the task asked me to check it) The 385-vs-595 discrepancy is real, correctly diagnosed, and the draft's choice is the more defensible of the two — but only *given* the partial-day-inclusion choice above

I recomputed both sides from the draft's own Step 4b data independently rather than trusting the
assertion:
- Per-day-then-average (the draft's choice): calories per day = {Mon 240, Tue 500, Thu 100, Fri
  700}, average = 1540/4 = **385**. Matches.
- From-averaged-grams (the rejected alternative): avg(protein) over the 4 days that logged protein
  = 175/4 = 43.75; avg(carbs) over the 2 days that logged carbs = 120/2 = 60; avg(fat) over the 2
  days that logged fat = 40/2 = 20. 4(43.75) + 4(60) + 9(20) = 175 + 240 + 180 = **595**. Matches.

So the two numbers genuinely differ, and the mechanism is exactly what the draft says: `avg(protein)`,
`avg(carbs)`, and `avg(fat)` are each computed over a *different subset of days* (4, 2, and 2
respectively) because of partial logging, so adding them together mixes incompatible denominators.
This is not a bug in either formula per se — it's the mathematically predictable consequence of
"average over the days that have a value" (D9) applied independently per base field, combined with
deriving a figure from three such averages. The draft's chosen approach (compute per item first,
then average) avoids mixing denominators and is the right call *relative to the alternative*. But
note this is the identical underlying cause as Findings 1–2: all three observations (the 385/595
split, the inflated protein share, and the downward-biased calorie average) are different symptoms
of the same root cause — partial per-day macro logging — so fixing Findings 1/2 (e.g. requiring
full macros for calories) would also make this discrepancy moot in practice, since the two formulas
become identical once every day contributing to calories has all three macros.

---

## Worth considering

### 4. (Alternative) "Days included" (item_count) can read as inconsistent with what's actually behind each average

`item_count` (the top "Days included" card) counts every item in the period regardless of data —
in the Step 4b fixture, 6 days, including two with zero data. Underneath, Calories' basis line says
4 days, Weight's says 2, Carbs'/Fat's say 2. This is disclosed (each card's own basis line shows its
own `n`), so I'm not flagging it as incorrect, but the top-level count card and the per-card "n
days" lines can tell different stories at a glance (a dashboard that says "6 days included" sitting
above a Weight card based on only 2 of those days), especially for a user skimming the headline
numbers rather than reading each basis line carefully. Consider either relabeling the top card
("Days tracked") to avoid implying it's the denominator for every card below it, or giving it a
one-line explanation the first time it's shown.

### 5. (Alternative, minor) Known approximation callout (Atwater 4 kcal/g on total carbs, including fiber) is fine as scoped

The draft already documents this as a deliberate, user-specified approximation and cites that
scan-plate's own plausibility check uses the same assumption. I verified the premise independently
(fiber's true energy yield is lower, ~1.5–2 kcal/g, because it isn't fully metabolized) but this is
explicitly in-scope as the user's chosen spec, not something the draft got wrong — flagging only so
it's clear I checked it and it's not a hidden error, not asking for a change.

### 6. (Alternative, minor) The two-level `item_agg`/`period_agg` vocabulary is sufficient for what's being built here, deliberately narrow for derived fields

I checked whether `item_agg`/`period_agg` is adequate for calories or needs its own aggregation
vocabulary, per the task's prompt. It's adequate: derived fields skip `item_agg` entirely (computed
as a per-item weighted sum of present components, which is its own well-defined "item-level"
operation) and still use `period_agg` for the across-days step, which is the same semantic as any
base field. The validator correctly requires weight components to be base fields (no
derived-of-derived) and positive weights (shares would be meaningless otherwise). This is already
self-aware in the draft's "Constraints, deliberately narrow" note, so I'm not asking for more
generality here — if anything, this is a case where the draft correctly avoided overbuilding (no
expression language, no negative-weight/"profit" support it doesn't need yet).

### 7. I independently re-traced the per-stage dedupe/snapshot mechanism (D1/D9) through all of Step 4b's checks 2–4 (back up and correct a value, forward skip out of the same stage) by hand against the actual SQL, not just the draft's stated expected values, and got the same numbers the draft asserts (50, then 55, then 60) for the reasons the draft gives. I found no error in this part. The already-acknowledged "D1 residual" (Section A.2) is real and correctly characterized, not newly discovered.

---

## Summary

- Findings by category: 2 critique (both "must address," both rooted in the same underlying
  partial-macro-day issue), 1 verification (confirms the draft's math is right, with a caveat tying
  it back to the same root cause), 3 alternative/minor (worth considering, none blocking), plus one
  item (7) recording that I independently re-verified the dedupe mechanism and found nothing wrong.
- Nothing here is a SQL bug, a wrong aggregation formula, or an infeasible step. The CHECK
  validator, the RPC's two-level aggregation, the snapshot/dedupe design, and the 385-vs-595 test
  case all hold up under independent recomputation.
- What should block advancing as-is: Findings 1 and 2 describe a real, currently-unacknowledged
  product decision (how to treat partial-macro days in the one derived, most-visible metric) that
  the plan decided implicitly rather than surfacing in Section A the way it did for A.1/A.2. Given
  that real dev data already exhibits this (multiple current-week items are breakfast-only), I'd
  ask the user to explicitly choose one of the Finding-1 options before implementation, the same
  way A.1 and A.2 were raised — this is a small addition to the plan, not a rework, but it
  shouldn't be skipped.
