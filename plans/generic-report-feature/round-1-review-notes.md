# Round-1 plan review: generic per-workflow Report

Reviewed as the engineer who has to execute this cold, against the current repo state
(migrations through `20261113000000`, `WorkflowDetail.razor`, `WorkflowApiClient.cs`,
`PROGRESS.md`). Scope: completeness, internal consistency, executability, ambiguity — not
whether the technical design itself is correct.

Overall this is an unusually well-grounded draft: every factual claim about the existing
schema, RLS pattern, and Razor file I checked against the actual code matched (line numbers
in Section 0.2, the `move_stage` body in Section 0.1/Step 1, `create_item`'s 2-arg overload
used in Step 4, `item_events.seq` as bigserial, the list-view gating in Step 6b all check
out). The issues below are mostly small gaps/ambiguities, not structural problems.

## Issues

1. **Step 4's transaction test leaves `<id>` as a literal placeholder across five statements,
   with no instruction for how to carry it between them.** (Lines ~611–619.) `supabase db
   query --linked` and most non-interactive SQL runners don't let you capture `select id from
   public.create_item(...)` into a session variable and reuse it in later statements without
   `psql`-style `\set` or a `do $$ ... $$` block. The plan says "note id" but doesn't say how
   (a `psql` variable? wrapping the whole thing in a `do` block with a `declare v_id uuid`?).
   Section 0's own assumptions list flags uncertainty about whether `supabase db query --linked`
   can even hold a multi-statement transaction, but doesn't extend that doubt to variable
   capture specifically. Someone executing this literally will stall here and have to guess
   (most likely: rewrite it as a `do $$` block, or run it by hand in the dashboard SQL editor
   substituting the UUID manually after each step) — worth spelling out directly rather than
   leaving the mechanics implicit.

2. **Step 4's `<the Nutrition account owner user_id from account_members>` has no query given
   to actually fetch it**, unlike every other placeholder in the plan which is resolved by a
   nested `select`. A reader has to independently construct `select user_id from
   account_members where account_id = (select account_id from workflows where name =
   'Nutrition Tracker')` (or similar — the plan never shows `account_members`'s columns), and
   guess which of possibly several members is "the owner" if there's more than one. Minor, but
   it's the one unresolved placeholder in an otherwise copy-pasteable script.

3. **Step 6c, "Range chips" table says `from` is "the start of the earliest period," but never
   states which calendar point "start" means for `week`/`month` relative to the chip count.**
   E.g. for the `week` period with the "26 weeks" chip, is `from` computed as
   `date_trunc('week', today) - 25 weeks`, or `- 26 weeks`? Off-by-one here changes whether the
   current partial week counts as one of the 26. The SQL side (`report_series`) takes raw
   `p_from`/`p_to` dates and leaves this entirely to the client, but Step 6c's load-sequence
   section (item 4) doesn't pin down the arithmetic the way Step 2's RPC pins down
   `date_trunc`. An implementer has to guess which boundary convention to use.

4. **Step 6c item 6 says period steps use "Monday-start weeks to match Postgres," but the
   month-stepping rule is never stated**, even though months have variable length and the
   period list must still align with `date_trunc('month', ...)` on the server. It's implied
   ("step by period") but not spelled out the way the day/week cases implicitly are via
   `date_trunc`. Not a large gap, but it's the kind of thing two people would code differently
   (e.g. `AddMonths(1)` from an anchor vs. recomputing `date_trunc`-equivalent boundaries each
   time) and it only surfaces as a subtle chart misalignment bug, not a crash.

5. **D7 / Step 6c name the color "the accent color" for an unmet goal status**, matching the
   file's existing `var(--app-accent)` convention seen elsewhere in `WorkflowDetail.razor` —
   but the plan never says this explicitly, so it's an inferred mapping rather than a stated
   one. Likewise "green when met" doesn't name a CSS value/variable; if the codebase has no
   existing green token, the implementer has to invent one. Small, but it's exactly the kind of
   underspecified visual detail that produces a plausible-but-wrong guess.

6. **Minor naming slip in Step 6c:** "the selected one `Appearance.Primary`" (under "Range
   chips") doesn't match the actual API used elsewhere in the codebase, which is
   `ButtonAppearance.Primary` (confirmed in `WorkflowDetail.razor`, e.g. line 44, 115, 265).
   Trivial to fix in review, but as written it's wrong if copied literally.

7. **Step 9 says "Commit the migrations, client, pages and JS together," but Step 7's mechanic
   dry-run (explicitly rolled back) and Step 8's manual UI checks are not mentioned as needing
   to happen before that commit.** The step ordering (migrations → client → UI → dry-run →
   build/deploy → commit) is recoverable by reading Steps 1–8 in order, but Step 9 doesn't
   restate "after Step 8's checks pass" the way Step 4 explicitly gates on Step 3's diff. A
   reader skimming just the step headers could plausibly commit right after Step 6 and treat
   Steps 7–8 as optional verification rather than gating steps. Low ambiguity risk since the
   numbered order is the obvious read, but worth an explicit one-line gate given how much care
   Step 4 puts into similar sequencing language.

8. **Section 4 ("Assumptions not verified") lists "Date input... binds cleanly to `DateOnly`"
   and "Goal directions... confirm with the user," but doesn't say what to do procedurally if
   either assumption fails beyond "bind to a string and parse" / "it's content only, a one-line
   change."** That's enough to unblock an implementer, but Section 4's other two entries
   (PostgREST schema cache, browser timezone) get concrete fallback *mechanisms*
   (`notify pgrst, 'reload schema'`, retry-with-UTC-and-show-a-note) while these two get vaguer
   fallbacks. Inconsistent level of detail across the same list, not a gap that blocks
   execution.

## Not flagged as issues (checked, found consistent)

- File/migration names, function names, and column names are used consistently across
  Sections 0–3 and the SQL bodies (`report_config`, `report_series`, `report_goals`,
  `jsonb_numeric`, `cleared`, `v_cleared`).
- Step 1's instruction to copy `20261113000000`'s body and diff it in Step 4 is concrete and
  checkable — the actual file matches what Section 0.1/Step 1 describe.
- Step 5's claim that `GetWorkflowsAsync`'s 3-argument `WorkflowSummary` construction still
  compiles after adding a trailing optional 4th parameter is correct given the current file
  (`WorkflowApiClient.cs` lines 58–80).
- Step 6b's insertion point for the Report link (`WorkflowDetail.razor`'s list-view `else`
  branch, after the Show/Hide-closed link) is in the generic, non-job-gated branch, matching
  the plan's claim that it applies to any workflow with `report_config` set, not just jobs.
- `create_item`'s 2-arg overload (used in Step 4's test) exists and matches the plan's call
  signature; `update_data`'s signature also matches.
- D1's invariant and the backward-then-forward walkthrough are self-consistent, and the segment
  union in the RPC (live value ranked by `seq = max bigint`, cleared values ranked by their
  event's actual `seq`) matches the stated "live value ranks after every cleared snapshot" rule.

## Verdict

No issue here rises to "wrong" or "contradicts an earlier step" — they're all places where an
implementer following the plan literally would have to pause and make a small judgment call
the plan didn't make for them (chip-boundary arithmetic, month-stepping, a missing variable-
capture mechanism in one SQL script, one unresolved query placeholder). Items 1–4 are the ones
worth tightening before build; 5–8 are polish.

**This plan does not need a full extra draft round.** It's executable as-is by someone willing
to make the handful of small calls above, and all of them are cheap to get wrong and cheap to
fix (a chart off-by-one period, a copy-paste SQL stall) rather than silently-wrong-forever
mistakes. Recommend folding items 1–4 into this draft with a light edit pass (no new design
decisions needed) rather than spinning up round 2.
