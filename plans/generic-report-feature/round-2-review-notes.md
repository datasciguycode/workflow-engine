# Round-2 plan review: generic per-workflow Report

Reviewed cold, as the engineer who'd execute this, against the current repo state
(migrations through `20261113000000`, `WorkflowDetail.razor`, `WorkflowApiClient.cs`,
`index.html`, `PROGRESS.md`), and cross-checked against `round-1-draft.md`,
`round-1-review-notes.md` and `round-1-sanity-check.md`. Scope: completeness, internal
consistency, executability, ambiguity — not whether the technical design itself is correct
(that's the parallel sanity-check pass).

## Round-1 feedback actually resolved

Both round-1 documents' findings are addressed in round 2, and the "Feedback from this
round" section's self-reported mapping checks out against the actual round-1 files:

- All 8 plan-reviewer items (variable-capture mechanism, owner-lookup query, chip
  arithmetic, month stepping, color tokens, `ButtonAppearance.Primary`, Step 9 gating,
  Section 4 fallback-detail parity) are visibly folded in (Section 0.2, Step 4's owner
  query, Step 6c's `PeriodStart`/`NextPeriod`/`AddPeriods`, Section 0.4, Step 9, Section 4).
- Both sanity-check blocking items (double-counting, the NULL-passing CHECK) are addressed
  with scoped fixes (D1's dedupe-by-`from_stage_id`, the `?&`/`coalesce`-guarded CHECK in
  Step 2), and all four non-blocking items are explicitly accepted or rejected with reasons.

No round-1 item was silently dropped. Code-level claims I spot-checked against the repo —
`WorkflowSummary`'s 3-argument constructor, `ItemDisplayName`'s current `{item.CreatedAt:yyyy-MM-dd}`
line, the `back-link`/"Show closed" insertion point in `WorkflowDetail.razor`, `focus.js`'s
`<script>` tag in `index.html`, the existence of `SearchItemsAsync`/`AddChatMessageAsync` as
the methods Step 5 says to pattern-match — all matched what's actually in the files.

## Issues found in this round

1. **Step 4a's second query is described, not given.** (Lines ~625–640.) The plan shows the
   full `supabase db query --linked "select * from public.report_series(...)"` command for the
   `America/Chicago` case, then says "Re-run with `'UTC'` and expect 3 rows..." without showing
   the re-run command. It's a one-argument substitution and low-risk to get right, but it's the
   one place in an otherwise copy-pasteable verification section where the reader has to build a
   command themselves rather than run what's printed — inconsistent with how carefully every
   other query/DO-block in Steps 4/7 is spelled out verbatim.

2. **Step 5's `ParseReportConfig` doesn't state defaulting behavior for `unit_position` and
   `goal_direction`.** (Lines ~826–831.) It explicitly says what happens when `key` is missing
   or `agg` is unrecognized ("skips fields..."), but is silent on what the parser does when
   `unit_position` or `goal_direction` is absent or an unrecognized string. D3's table gives
   defaults (`suffix`, `at_least`) for the *config shape*, but Step 5 never says the C# parser
   actually applies those defaults rather than, say, leaving a `bool` at its CLR default or
   throwing. An implementer has to infer "apply D3's defaults" by cross-referencing a different
   section rather than being told directly in the step that writes the parser.

3. **Minor terminology wobble: "the start of the range" vs the chip table's actual semantics.**
   Step 6c's prose (load-sequence item 4) is fully worked with formulas and two examples, so this
   isn't a repeat of round 1's ambiguity — but the phrase "Range chips" (the UI section) and
   "the selected chip" (load-sequence item 4) are used as if self-evidently the same control, and
   the chip *values* (7/30/90 etc.) only appear in the load-sequence table, not next to the
   "Range chips" rendering bullet itself. A reader building the rendering section in isolation
   would need to jump back to item 4's table to know what the three buttons actually say. Low
   severity — the information is present and unambiguous, just split across two places without a
   cross-reference.

4. **Step 9's "commit everything in one commit" instruction and the immediately following note
   are in slight tension.** (Lines ~1068–1073.) The bullet says to commit "the three migrations,
   `scripts/report_series_dev_check.sql`, `scripts/report_mechanic_dry_run.sql`, the client, the
   pages and the JS" in one commit, then the very next bullet says Step 8's deploy push already
   put the web code on `main`, and if a single commit is wanted, Step 8's checks should be run
   against local `dotnet run` first — deferring the push to Step 9. As written, Step 8 (lines
   1038–1043) unconditionally says "push to main" (gated only on "the user's go-ahead"), while
   Step 9 retroactively says that push might need to *not* happen yet, depending on a preference
   that's never surfaced to the executor until Step 9. An implementer who follows Step 8 literally
   on first read has already split the commit before reaching Step 9's caveat. This is flagged
   honestly as "the user's call" in both places, but the plan doesn't say *when* that call needs
   to be made (i.e., before Step 8's push, not after) — so as sequenced, by the time you read the
   caveat it's too late to act on it.

5. **Section 4's PostgREST-cache fallback and Step 4's own structure aren't cross-referenced.**
   Minor: Section 4 says to detect a stale schema cache via a 404/PGRST202 on the *report page*,
   but Step 4a's direct RPC check (run immediately after `db push`) would hit the identical
   failure mode first and is the more natural place to notice and apply the `notify pgrst,
   'reload schema'` fallback. Not wrong, just split from where it'd actually first surface —
   someone running Step 4a who gets a PGRST202 has to go find Section 4 to learn what it means
   and how to fix it, since Step 4 itself doesn't mention the possibility.

None of these rise to "blocks execution" or "contradicts an earlier step" — each is a small
place where the reader has to cross-reference another section or make a trivial substitution
the plan doesn't spell out verbatim, in a document that is otherwise unusually disciplined
about doing exactly that everywhere else. Item 4 (the commit/push sequencing tension) is the
one worth tightening with an actual wording change, since it's a timing issue rather than a
pure information-location issue; items 1, 2, 3 and 5 are polish.

## Verdict

**This plan does not need another draft round.** It is complete and internally consistent:
named files, functions, columns and config keys match across every section and match the
actual repository state everywhere I checked; the three migrations, the client changes and the
UI steps are sequenced in an order that is actually executable; and round 1's full set of
findings (both review and sanity-check) is visibly and correctly folded in rather than merely
asserted. The five issues above are all small, cheap-to-fix clarifications (a missing verbatim
command, an unstated default-fallthrough, a cross-reference gap, a commit/push timing wrinkle,
and a fallback that isn't flagged where it would first appear) — appropriate to note in review
but not serious enough to justify delaying implementation for a third draft.
