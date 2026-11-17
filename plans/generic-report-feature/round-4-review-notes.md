# Round-4 draft review notes (structure / communication lens)

Scope: `plans/generic-report-feature/round-4-draft.md`, read fresh (round-3-draft.md not
consulted for anything except verifying the audit trail in "Changes from round-3-draft.md" and
the two round-3 reviewer files, which were used only to check that round 4 accurately closed out
their items).

## Overall

This is a tightly-edited, mostly self-contained document. The numeric claims that recur across
sections (the A.4 table, the Feedback table, the 4b check-6 assertions, the Step 4a cross-check)
were independently re-derived and are internally consistent — I did not find a single place where
a figure quoted in one section contradicts the same figure quoted elsewhere. The three targeted
fixes from round-3-review-notes.md are each verifiably complete, not just surface patches (detail
below). The new Decision A.4 is clearly structured and gives genuine, differentiated cost
estimates for each option.

## Specific checks requested

### 1. Is Decision A.4 written clearly enough to decide without follow-up questions?

Mostly yes. All three options state what changes and roughly how much code/SQL it costs, with a
literal SQL snippet for option (a) and concrete C#/Razor deltas for (b). One asymmetry worth
calling out:

- Option (a) gives a complete, drop-in SQL replacement for the `item_terms` CTE.
- Option (b) says `field_complete` is "computed with the same count comparison as (a)'s
  `item_terms`, but used only for counting" (lines ~102–105) — this asks the implementer to
  extract and adapt logic from a sibling option's SQL rather than handing them literal SQL of its
  own. Everywhere else in this document (the migrations, the 4b script) is written to be copied
  verbatim; this one spot requires inference. Not a blocker — the comparison logic is fully
  specified in (a) just above it — but it's the one place in A.4 where "no follow-up questions
  needed" is a slightly generous claim.

A second, smaller ambiguity: the paragraph right after the three options ("If you choose (a) or
(b), the Step 2 SQL and Step 4b script change... so re-run them there before Step 4") reads as if
it's the complete punch-list of follow-up work, but it only covers the SQL/4b re-verification. The
actual new work for (a)/(b) also includes the Step 5 record field (b) and Step 6c UI changes
(a and b), which are described back in each option's own cost bullets but not repeated or
cross-referenced in this closing paragraph. A reader skimming only the closing paragraph could
under-scope the work. Minor clarity issue, not a gap in the underlying information (it's all
present, just not gathered in one place).

### 2. Does everything downstream of A.4 point back to it, or does anything assume one option implicitly?

Checked every place the document computes or displays calories/split and confirmed each either
(a) documents the current (option-c-shaped) behavior as the literal current default, explicitly
flagged as "your choice" if left alone (A.4 option (c)'s own text says this), or (b) points back
to A.4 by name:

- D10 step 1 ("**Pending A.4:**...") — points back.
- Step 6c's split legend ("If A.4 picks (a), the grams become... and (b) adds a completeness
  caption. See A.4.") — points back.
- Step 8 check 2 (phone check) — points back ("with A.4 option (a), they match... instead").
- Section 5's risk bullet — points back ("How the report handles it is Decision A.4, still open").
- Step 9 — lists A.4's outcome as something to record at the next milestone.
- The shipped Step 2 SQL and the 4b check-6 assertions implement option (c) (current behavior)
  without a comment inside the SQL itself saying "this is A.4(c) pending confirmation" — but this
  is explicitly covered by the A.4 text itself ("(c) Keep the current behaviour... The Section 5
  bullet records it as your choice"), so it's not a silent assumption, just not locally
  commented at the SQL. Acceptable given the explicit framing elsewhere, but a one-line SQL
  comment pointing at A.4 would have made Step 2 fully self-auditing on its own.

No spot was found that assumes (a) or (b) without flagging it.

### 3. Are the three round-3 review-note fixes actually complete?

All three verified against round-3-review-notes.md's original wording, not just taken on faith:

- **Fallback rows split.** Step 5's parser table now has two separate rows, one for `count_label`
  (falls back to `ItemLabelPlural`) and one for `item_noun` (falls back to `item_label`), matching
  the original review note's exact complaint. Fixed completely.
- **"24 probes" → 13 cases.** Step 2's Notes now name 13 categories in the same order as the 13
  literal configs in the `do $$` block's `foreach` array (I matched each of the 13 prose
  descriptions to its corresponding SQL literal one-for-one — they line up exactly). The
  remaining validator branches are now explicitly labeled as verified by reading the SQL only,
  with an example of how to add them as executable cases later. This is a complete and honest
  fix, not just a reworded claim.
- **`period_agg: last` tie-break.** D9's prose states the tie-break (greater `items.id` wins) and
  the actual RPC SQL's `array_agg(... order by its.created_at desc, its.id desc)` implements it.
  D9 also explains why `item_agg: last` needs no such tie-break (orders by `seq`, which never
  ties). Both the narrative and the code agree. Complete.

### 4. Does "Changes from round-3-draft.md" accurately and completely describe the diff?

Cross-checked each of its 5 bullets against the document body and against round-3's reviewer
files (sanity-check and review-notes) where relevant. All 5 bullets are accurate as far as they
can be verified without round-3-draft.md itself, and the "Feedback from this round" table's
mapping of round-3 findings to adopted/not-adopted outcomes matches round-3-sanity-check.md's and
round-3-review-notes.md's actual finding numbers and severities (I checked finding/note numbering
directly against those files). One phrasing note: the closing line "Nothing else changed. The
Step 2 SQL differs from round 3 only by the tie-break's `, its.id desc`..." sits directly under
the 5-item change list and could momentarily read as contradicting items 3 and 4 above it (the
probe-count and fallback-table fixes are real textual changes to this round). On a careful read
it's correctly scoped to "the Step 2 **SQL**" specifically (as opposed to the surrounding prose
Notes, or the Step 5 C# table), and is accurate under that reading, but the juxtaposition invites
a half-second of doubt. Consider either moving this sentence away from directly under the
change list, or qualifying it explicitly ("the SQL code itself, as opposed to the Notes/table
changes above").

### 5. Any new inconsistency introduced by this round's edits?

None found. Specifically checked and found consistent:
- The A.4 table's numbers (385/600 kcal, 45/31/23 vs 30/40/30 splits) against the 4b check-6
  assertions (385, shares 0.4545/0.3117/0.2338) and against the Feedback table's re-derived totals
  (700/480/360 of 1540; 360/480/360 of 1200) — all three independently recompute to the same
  figures from the same underlying per-day macro values.
- Section 0.1's ground-truth table (`8c4775d6` now at "lunch... re-checked for round 4") against
  D2's prose and the Step 1 migration comment's "2026-11-15's day" reference — all three agree.
- The claim that no current dev item is a partial-macro day is stated three times (A.4's "How
  often this happens," Section 0.1's closing line, and Section 5's risk bullet) with identical
  substance each time — no version overstates urgency or drops the caveat.

## Verdict

No issues found here rise to "needs another draft." The three required fixes are genuinely
complete, the new Decision A.4 is clear enough to act on (with one minor asymmetry in option
(b)'s SQL specification and one minor scoping gap in its closing paragraph, both easily patched
inline rather than requiring a new round), and the changelog is accurate. The live-dev-data
caveat the task asked me to verify is handled honestly throughout — the document says plainly
that A.4 doesn't change today's numbers, and never implies urgency it hasn't earned.

Recommendation: **ready to advance to final architect review**, optionally with the two small A.4
clarifications above folded in either now or at the next pass; neither is load-bearing enough to
warrant another full review round on its own.
