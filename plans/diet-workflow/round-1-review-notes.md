# Round-1 review notes: Diet workflow plan

Reviewed as the plan-reviewer stage (structure/communication lens: completeness, internal
consistency, executability, ambiguity — not technical correctness, which is the sanity-check
agent's job). Cross-checked the plan's factual claims against the actual files it cites:
`web/Pages/WorkflowDetail.razor`, `web/Services/WorkflowApiClient.cs`,
`supabase/functions/scan-vin/index.ts`, `supabase/functions/agent-loop/index.ts`, and the
relevant `supabase/migrations/*.sql` files (phase0, phase1, phase4b, and the fix-overload
migration).

## Fact-check summary (unusually strong for a round-1 draft)

Every concrete, checkable claim in the plan that I tested against the real code turned out to
be accurate, often to the exact line and exact string:

- Line numbers cited for every `WorkflowDetail.razor` edit (9a line ~42, 9b line 56, 9c's
  insertion point "after line 90, before the `scheduled_at` block", 9d line 118, 9f lines
  183-186, 9g lines 220-233, 9h line 256, `ItemLabelPlural` line 396, `ItemTitle` fallback line
  520) all match the current file exactly, down to whitespace.
- `WorkflowSummary`, `GetWorkflowsAsync`/`GetWorkflowAsync`'s `select=` list, `Home.razor`'s
  read-only use of `WorkflowSummary`, `DoneNextStage`'s existing
  `Checklist.Except(OptionalChecklist)` logic, and `VisibleItems`'s current terminal-stage
  filter all match the plan's description verbatim.
- The `create_item` overload history (phase0 creates the 3-arg version and grants it to
  `authenticated`; phase1 drops that 3-arg version and grants a new 2-arg version; phase4b's
  `create or replace` silently re-creates the 3-arg signature with no explicit grant) matches
  the plan's section-0 narrative and justifies D8's "re-issue the grant explicitly, idempotently"
  decision.
- `stages`'s `unique (workflow_id, title)` constraint (used for Migration B's `on conflict`)
  exists exactly as described, in phase0.
- No existing migration uses the stage titles `breakfast`/`lunch`/`dinner`/`snack`/
  `nutrition_goal`, so the plan's "no collision" claim for Migration B holds.
- The exact exception text `'workflow % has no is_initial stage'` and the "mechanic-shop /
  task-tracking app" prompt wording and the "skip it only if the item is already at a terminal
  stage" nudge all exist verbatim in `agent-loop/index.ts`, supporting the plan's Problem 3 and
  the Risks section's "agent-loop prompt text says mechanic-shop" note.
- `scan-vin/index.ts` lines 30-59 are exactly the OPTIONS/405/401/400/400 block the plan tells
  the implementer to copy verbatim into `scan-plate`.
- No `[functions.scan-vin]` or `[functions.agent-loop]` block exists in `config.toml` (only
  `mcp-server` has an override), confirming the claim that omitting a `[functions.scan-plate]`
  block leaves `verify_jwt` on by default, same as those two.
- The referenced test photo (`50cc0461-image.jpg`, 1,292,610 bytes ≈ 1.29 MB) exists at the path
  given in Step 7, and the scratchpad path used there matches the session's actual scratchpad
  directory.

I did not find any place where the plan misdescribes the current code, contradicts itself
between sections, or skips a necessary step (migration → deploy → verify → client → UI → test →
commit is a complete, correctly-ordered chain, and D1-D11 are each cashed out by a concrete step
later in the doc).

## Issues found

All of the following are minor; none would block an engineer from executing the plan
correctly, but each is a small gap in what's spelled out.

1. **Section 1.4 ("Hardcoded 'Job' text")'s list is incomplete, and Step 9 doesn't fix the
   missed instances.** `WorkflowDetail.razor` has two more hardcoded `Job #@JobNumber(item)`
   occurrences inside the "Other Appointments" blocks (around lines 108 and 173, one in the
   stage view, one in the `_newJobMode` branch) that aren't in the plan's enumerated list and
   aren't touched by Step 9's edits. This causes no visible bug for Diet specifically, because
   those blocks are gated on `Checklist.Contains("scheduled_at")`, and no Diet stage has that
   field — but the plan's own framing ("Every one of these can switch to
   `ItemLabelSingular`/`ItemLabelPlural` with zero visible change") overstates what was actually
   covered. Worth a one-line acknowledgment (either "also missed, left for a future workflow
   that combines `scheduled_at` with a non-"job" label" or just folding it into the fix) so a
   future reader doesn't think this sweep was exhaustive.

2. **Step 9's per-edit line numbers are all given against the *original*, pre-edit file, but
   nothing says so explicitly**, and earlier edits in the same step shift everything below them
   (most notably 9c, which inserts a whole new block between the cited lines for 9b and 9d). An
   implementer applying edits literally "by line number, in order" could get confused once they
   reach 9d expecting line 118 to still be the job-overview heading. In practice this is a
   non-issue because every edit also comes with enough unique surrounding text/code to locate it
   by content instead, but the doc never says "these line numbers are all against the file as it
   exists before you start Step 9" — worth one clarifying sentence.

3. **Step 9b shows only a substring before/after** (`Job #@JobNumber(_selectedItem)` →
   `@ItemLabelSingular #@JobNumber(_selectedItem)`) rather than the full line, which also
   contains a `style=` attribute and the `&mdash; @StageTitle(...)` suffix that aren't repeated.
   It's inferable that this is a surgical substring swap rather than a whole-line replacement,
   but a one-word qualifier ("...leaving the rest of the line unchanged") would remove any doubt.
   Same minor pattern applies to 9d's before/after.

None of these rise to the level of "needs another draft" — they're all copy-edit-sized gaps that
an engineer executing this plan would almost certainly resolve correctly on their own (the
missed `Job #` instances are inert for Diet; the line-number drift is solvable by content
search), not places where they'd have to guess at intent or where two readings diverge in a way
that changes behavior.

## Verdict

The plan is complete, internally consistent, and executable as written. The ground-truth
section's claims about the database, the migration history, the client code, and the edge
functions are all independently verified against the actual repository and hold up exactly —
this is a notably well-fact-checked round-1 draft. The three issues above are polish-level and
don't require another revision round on their own. **Ready to advance to architect review**,
optionally with a one-line fix to item 1 (acknowledge or close the two missed `Job #` spots) if
the author wants to tidy it up first, but that shouldn't block moving forward.
