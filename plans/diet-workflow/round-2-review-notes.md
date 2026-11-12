# Round-2 plan review (structural / communication lens)

Reviewed cold, against the current state of the repo (`web/Pages/WorkflowDetail.razor`,
`web/Services/WorkflowApiClient.cs`, `supabase/functions/scan-vin/index.ts`,
`supabase/functions/agent-loop/index.ts`, and the migrations directory), without reading the
round-1 reviews.

## Headline finding

This draft is unusually precise for a plan of this size. Nearly every falsifiable claim I checked
against the live file matched exactly, including ones most plans would get slightly wrong:

- Step 9's cited line numbers (42, 56, 90/91, 108, 118, 141–179, 183–186, 211–216, 220–233, 396,
  403, 520) all match the current `WorkflowDetail.razor` verbatim, including the quoted "before"
  text.
- The claimed indentation difference between the two identical `Job #@JobNumber(item)` lines (28
  spaces at line 108 vs. 24 spaces at line 173) is exactly right — I counted both.
- `grep -n 'Job #' web/Pages/WorkflowDetail.razor` today returns exactly the 5 lines the plan
  predicts (56, 108, 118, 173, 403), and Step 9's edits (9b/9c′/9d/9e/9i) account for all four
  live occurrences, leaving only the comment at 403 — matching the plan's own "post-edit check"
  claim.
- Step 6b's agent-loop line numbers (115, 175, 193–197, 412) and the exact quoted description
  text ("It lands automatically in the workflow's is_initial stage. ") match the current
  `agent-loop/index.ts` precisely, down to the case-block body being lines 193–197.
- The `create_item` overload history in Section 0 ("dropped in phase1, then re-created by
  phase4b's create or replace") checks out against the actual migrations: phase0 creates the
  3-arg function, `20261012154028_phase1_is_initial_and_seq.sql` drops it, and
  `20261016130000_phase4b_item_events_stage_id.sql` recreates it via `create or replace`.
- `validate.ts`'s logic and `validate_test.ts`'s assertions are mutually consistent — I traced
  every test case (numericString, missingKey, negative, overFieldCap,
  fiberPlusSugarOverCarbs, allZero, overKcal, notFood, garbage, the carb-subset-slack case, and
  the fenced/prose-wrapped case) against `parseEstimate`'s logic by hand; all pass or fail exactly
  as asserted, and the manually-estimated kcal figure in Step 7's pass criteria (672 kcal) matches
  what `parseEstimate` would compute from the same numbers.
- The client-side records/methods the plan edits (`WorkflowSummary`, `ItemSearchResult.JobNumber`,
  `MoveStageAsync`, `ScanVinAsync`, the `select=id,name,item_label` query strings) all exist today
  exactly as described, so Steps 8a–8d are accurate instructions, not guesses.

I did not find a single place where a named file, function, column, or line reference in the plan
was wrong.

## Issues found

1. **Step 7's test photo is pinned to a session-scoped path that won't survive to execution time.**
   The curl command hard-codes
   `/home/mmcbride/.claude/uploads/750872d2-abc1-4109-ae9e-41bd21b23f2f/50cc0461-image.jpg`. That
   directory is keyed by this planning session's own UUID — I confirmed the file exists right now,
   but nothing in the plan tells the "implementing engineer" (explicitly called out in Step 7 as
   possibly a different person/session than whoever wrote the plan) what to do if that exact path
   is gone, which is the normal case once this session ends. The plan should either say explicitly
   "take your own photo of a plate with roughly known contents" with instructions for substituting
   it into the pass-criteria table, or save a durable copy of the reference photo somewhere outside
   session-scoped storage (e.g. committed as a fixture, or named in PROGRESS.md/the repo). As
   written, an engineer with "no more context than this document" who runs Step 7 in a later
   session has no path forward without guessing. This is the one real executability gap I found.

2. **Step 9's "locate by unique quoted text" promise is contradicted once, though the plan catches
   it itself.** The Step 9 preamble states: "Locate each edit by the quoted 'before' text, which is
   unique in the file." But the `Job #@JobNumber(item) &mdash; @when.ToString(...)` line appears
   verbatim twice (lines 108 and 173), and 9e's own text has to fall back to indentation ("24
   spaces... instead of 28") to disambiguate. The disambiguation is correct and sufficient, but the
   blanket uniqueness claim in the preamble is technically false for this one case. Minor — flagging
   for precision, not because anyone would actually get lost.

3. **Step 9f's "wrap in `@if (!AllStagesTerminal)`" instruction breaks the stated whole-line-diff
   convention.** The Step 9 preamble says "Every swap below is a whole-line replacement shown in
   full," and every other edit (9a–9e, 9f′, 9g, 9h) honors that by quoting exact before/after text.
   The Show/Hide-closed wrap in 9f is described only in prose ("Wrap the Show/Hide closed
   `FluentLink` in `@if (!AllStagesTerminal) { ... }`") with no literal before/after block, unlike
   its sibling edit on the same line region (the search placeholder, which does get an exact
   quote). It's recoverable from context (the three lines it must wrap are unambiguous in the
   current file), but it's a small inconsistency in how rigorously edits are specified within the
   same step.

4. **Minor: Step 4c's "copied from scan-vin lines 30–59" is off by one line.** In the current
   `scan-vin/index.ts`, the `Deno.serve` block (which the plan's elision starts from) begins at
   line 29, not 30; the required-fields check it should end at is line 59, which is right. Trivial,
   doesn't block execution, and the plan explicitly treats these as rough pointers elsewhere — but
   worth a note given how exact the plan is everywhere else, which makes this one small slip more
   noticeable by contrast.

## Not flagged (deliberately)

I'm staying out of the sanity-check agent's lane, but in the course of verifying claims I did
confirm (not evaluate the wisdom of) the following, since they bear on whether the plan can be
*executed* as written:
- The `AllStagesTerminal`/`ChatAvailable`/`DoneNextStage` changes are scoped correctly against the
  actual current `VisibleItems()`/`DoneNextStage()` bodies — the "before" code quoted in 9i matches
  the live file exactly.
- `validate.ts`'s `FIELDS` constant omits `weight_lbs`, consistent with the Migration B checklist
  (which includes `weight_lbs` alongside the five scanned macros) — scan-plate correctly doesn't
  try to estimate body weight from a photo.

## Verdict

No structural gaps, no internal contradictions beyond the two small items above (#2 and #3), and
every cross-checkable factual claim about the codebase held up under direct inspection. The one
real executability problem is #1 (the session-scoped photo path in Step 7), which is a localized,
easily-fixed omission — add a sentence about substituting a fresh photo and adjusting the
pass-criteria table — not a sign the design needs rework.

**This draft does not need another full revision round.** It's ready to advance to architect
review, with a note to patch Step 7's photo-sourcing instructions (and optionally tidy #2/#3)
either before or during that pass.
