# Round 6 sanity check (independent pass)

Scope: round-6-draft.md only, focused on what changed from round 5 (`item_requires`, the
uniform A.4 filter, the Step 4b test-script edits). Round 5/earlier substance is not
relitigated except where round 6 changes its effect.

## Verdict

No plan-blocking issues found. The core arithmetic claim checks out, the SQL logic for
`item_requires`/`kept` is correct and the "four numbers always agree" property is actually
a guaranteed algebraic identity (not a coincidence of the test fixture), and the Step 4b
strip/restore of `item_requires` around checks 2–5 does what it claims (isolates D1's
snapshot/dedupe testing from the new A.4 gate) without weakening those checks. Findings
below are all "worth considering," not blockers. Ready to advance to architect review as far
as this pass is concerned.

## Findings

### 1. (Alternative, worth considering) `item_requires` could be the full base-field set implicitly, with no new config property at all

For Nutrition today, `item_requires` (`["protein_g","carbs_g","fat_g"]`) is identical to
*every* base field in `fields`. Rather than adding a new top-level property, a new validator
function (`report_item_requires_valid`, ~25 lines), a new CHECK conjunct, and 6 new test
cases, the same outcome follows from a simpler rule: "an item must have a non-null value for
every configured *base* field, or it contributes to no field." That requires no schema
change — `kept` becomes "count of non-null item_base rows for this item == count of distinct
base_fields," with no `required` CTE or config key needed.

The draft does consider a nearby alternative ("an item missing any component of *any derived
field* is dropped from every field") and rejects it because it would make adding a future
derived field silently change base-field numbers (the mechanic-`profit` example). That
objection is valid for the derived-field-components version, but it doesn't apply to the
"all base fields" version: a new *base* field being added to `fields` already changes what's
displayed, so requiring it to also be logged before the day counts is a much smaller
surprise than a *derived* field reaching back into fields it has no visible relationship to.

This isn't a correctness problem with the draft's chosen mechanism — `item_requires` is more
general and lets a future workflow with many base fields (e.g., weight_lbs added later)
opt out of being part of the gate. But for the one real consumer, it is more machinery than
the stated requirement needs. Worth asking: does the user's "all four together" answer need
the generality of an arbitrary subset, or would "all configured base fields" have sufficed
and saved the validator/CHECK/test-case additions? Not blocking either way — the chosen
mechanism is correct and the draft already reasoned about a related alternative.

### 2. (Worth considering, not new to round 6 but sharpened by it) Uniform filtering compounds with the missing day-count to hide how little data backs an average

Round 5 removed the "Days included" card. Round 6 extends the exclusion filter from
calories-only to all four numbers, so a day that logs (say) protein only now disappears from
every card, not just Calories. The draft's own Section 5 already names this risk and the
user's trade-off explicitly, so this isn't an unflagged gap — but it's worth re-confirming
with the user now that the compounding is concrete: in the Step 4b fixture, only 2 of 6 test
days qualify, and nothing on the page would tell a real user "this average is based on 1 or 2
days" versus 7. Since this was explicitly surfaced and accepted in-plan (A.1/Section 5), I'm
not treating it as a gap in the plan, just flagging it for the final go-ahead conversation in
case the user didn't weigh the round-5-removal + round-6-filter interaction together.

### 3. (Minor correctness note, not a bug) The derived-field "every component required" rule and `item_requires` are redundant for Nutrition by construction

The draft already says this out loud ("after the gate the item_terms every-component filter
never removes anything... kept for workflows without item_requires"), so it's not an
oversight. Noting only that this redundancy is the direct consequence of finding #1 above:
two independent mechanisms (D10's engine-wide derived-field gate, and the new
`item_requires`) currently enforce the exact same constraint over the exact same three keys.
That's fine as designed-for-generality, but it's additional surface (two code paths producing
the same answer) to keep in sync if either is touched later.

## Verified, no issues

- **Arithmetic.** 4×45 + 4×60 + 9×20 = 180 + 240 + 180 = 600. Confirmed independently.
  Per-day: Tue (protein 40, carbs 40, fat 20) → 4·40+4·40+9·20 = 500; Fri (protein 50, carbs
  80, fat 20) → 4·50+4·80+9·20 = 700; avg(500,700) = 600; avg(protein) = (40+50)/2 = 45,
  avg(carbs) = (40+80)/2 = 60, avg(fat) = (20+20)/2 = 20. All match the draft's stated check-6
  fixture and expectations.
- **The "four numbers always agree" property is a guaranteed identity, not a fixture
  coincidence.** Because `item_requires` forces calories and the three macros to average over
  the *same* finite set of days (same denominator n), linearity of averaging guarantees
  4·avg(p) + 4·avg(c) + 9·avg(f) = avg(4p+4c+9f) exactly, for any data, not just the test
  week. This is a real strength of the design, correctly reasoned in D10.
- **The round-5-interim 43.75 and 595 claims.** Verified: under a calories-only filter,
  protein would average over all 4 logged-protein days (60, 40, 25, 50)/4 = 43.75, giving
  4·43.75 + 4·60 + 9·20 = 175+240+180 = 595 ≠ 600 — correctly illustrates the mismatch round 6
  fixes.
- **The 385 (option-c) claim.** Verified: (240 [Mon, protein-only×4] + 500 [Tue] + 100 [Thu,
  protein-only×4] + 700 [Fri]) / 4 = 1540/4 = 385. Matches.
- **`kept`/`required` CTE logic.** Correctly computes, per item, whether every listed
  `item_requires` key has a non-null `item_base` row, comparing counts rather than doing a
  join that could silently double-count (verified `item_base` has at most one row per
  (item, key), so no double-counting risk). Items with zero segments for a key (never
  logged at any stage) correctly fail to satisfy the requirement (no row, not a null row).
  Absence of `item_requires` degrades correctly to "every item passes" (0 = 0).
- **Validator (`report_item_requires_valid`).** Correctly distinguishes SQL NULL (property
  absent → valid) from JSON null (property present as `null` → invalid, since
  `jsonb_typeof('null'::jsonb)` is `'null'`, not `'array'`). Correctly excludes derived-field
  keys from matching (`not (g ? 'weights')`). Guards `jsonb_array_elements` against a
  malformed `fields` argument via the inline CASE, consistent with the "CHECK's AND doesn't
  guarantee evaluation order" discipline already used elsewhere in this file. The 33-case
  count (27 old + 6 new) was confirmed by direct count against the test array in the plan
  text.
- **Step 4b strip/restore of `item_requires` for checks 2–5, restore at check 6.** This is
  still testing what it claims. Checks 2–4 exercise D1 (per-stage snapshot capture and
  dedupe across forward moves/skips/back-corrections) using Mon's item, which in the shipped
  config would be dropped by `item_requires` before those assertions ever see it. Since
  `kept`/`required` only gates which items reach `period_vals`, and D1's segment
  capture/dedupe logic (raw_segments → segments → item_base) runs identically regardless of
  `item_requires`, stripping it for checks 2–5 does not change what those checks are actually
  verifying (stage-snapshot correctness) — it only removes an unrelated gate that would
  otherwise make the fixture's chosen "Mon logs only protein" design (needed to keep checks
  2–4's assertions clean) incompatible with the shipped config. Restoring the config at check
  6 is necessary and correctly ordered: checks 6–7 specifically exist to test the A.4/
  `item_requires` behavior, so they must run against the real shipped config. I traced the
  full day-by-day table (Mon 60/—/—, Tue 40/40/20, Wed —/—/—, Thu "25"/—/—, Fri 50/80/20, Sun
  —/—/—) against the script's sequence of operations and it is internally consistent with
  both check 4's assertion (protein 60 for Mon before the gate is restored) and check 6's
  assertion (Mon excluded after the gate is restored).
- **No double-filtering bug.** Where `item_requires`'s keys exactly match a derived field's
  `weights` keys (Nutrition's case), the two gates (D10's per-derived-field component check,
  and the new `item_requires` gate) are redundant but not contradictory — confirmed no
  interaction produces an incorrect result.
- **Step 4a live cross-check** correctly computes all four averages over the same "complete
  days" (`k`) and requires every `field_counts` entry to equal `complete_days`, consistent
  with the RPC's semantics.

## Not examined in depth (unchanged from round 5, out of this round's scope per the task)

D1 (per-stage snapshot capture), D2 (no backfill), D5 (timezone bucketing), D7/Step 6 UI,
Step 7 (mechanic dry run), and Section 6/8 scope cuts — these are unchanged by round 6 and
were not re-audited here.
