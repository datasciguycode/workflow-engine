# Review notes — round-1-draft.md (move_stage backward-move snapshot/restore fix)

Reviewed as the engineer who would execute this plan cold, against `plans/generic-report-feature/final-plan.md`, `CLAUDE.md`, and `PROGRESS.md`. Findings below are about structure, sequencing, and communication, not whether the SQL itself is correct.

## Issues

### 1. Step 9's "(at the milestone)" label conflicts with CLAUDE.md's definition of "milestone" — serious

Step 9 is titled `PROGRESS.md (at the milestone)`, and the one-paragraph summary ("Shape of the fix") and Section 1 item 4 both repeat that exact parenthetical. But `CLAUDE.md` defines "milestone" very specifically:

> A "milestone" is a specific, user-invoked request... Only run this when the user actually asks for it — not automatically at the end of every response.

Step 9 is presented as a plain numbered step in the plan's own sequence (1→9), run as part of finishing this plan, with no language making it conditional on the user separately invoking a milestone. That's a direct ambiguity for whoever executes this: do they do Step 9 unconditionally, right after Step 8, as the numbering implies — or hold off until the user says the word "milestone" (or asks to clear context), per CLAUDE.md? As written, the plan borrows CLAUDE.md's term but doesn't say which behavior it means, and the two readings produce different execution orders (see also issue 2). This should be resolved explicitly: either say Step 9 runs unconditionally as part of this plan's own close-out (and drop "at the milestone," which is misleading), or say it's deliberately deferred until the user invokes a milestone (and then Step 8's commit, below, can't include it).

### 2. Step 8's commit is specified to include content that, per the plan's own numbering and Step 9's label, doesn't exist yet — serious

Step 8 ("Commit, then push to `main`") says:

> One commit with: the migration; both scripts; this plan directory...; **the `PROGRESS.md` update from Step 9.**

Step 9 comes *after* Step 8 in the document and is labeled "(at the milestone)". Taking either reading of issue 1 literally, there's a problem:
- If Step 9 only runs at a later, separately user-invoked milestone (CLAUDE.md's definition), then Step 8's single commit cannot possibly include "the PROGRESS.md update from Step 9," because that update won't exist when Step 8 runs.
- If Step 9 is meant to run immediately as part of this plan (not deferred), then the step numbering is simply backwards: Step 9 needs to happen *before* Step 8's commit, not after it.

Someone executing top-to-bottom, in step-number order, will hit this contradiction directly. The plan needs to either renumber (make the PROGRESS.md edit Step 8a, before the commit step) or say explicitly "do Step 9 first, then come back and commit in Step 8."

### 3. Section A.1 has no stated path for a "no" answer — completeness gap

A.1 asks the user to "Accept the user-visible change..." and gives a default ("accept it") with a long explanation of why the rejected alternatives in D1 are worse. But the question is framed as a real yes/no decision ("Reply by number... 'Default is fine' counts as an answer"), and the plan never says what happens if the user answers "no." Unlike the Report plan's A.1 (which had a concrete, implementable alternative — `p_to = yesterday`), this plan's "alternatives" section (D1's a/b/c-alt) only explains why each alternative was *rejected by the plan's author*, not what to build if the user doesn't want the restore behavior at all. If the user declines, does implementation stop? Does the plan fall back to one of D1's rejected options? This should be stated, even if the answer is "a 'no' answer means stop and we replan."

### 4. Step 8 treats its own plan directory and the Report plan's directory inconsistently, with no explanation — ambiguity

Step 8 says the one commit includes "this plan directory (`plans/move-stage-backward-snapshot/`)" as a flat statement of fact — no question asked. Two sentences later, about `plans/generic-report-feature/` (also currently untracked): "Whether to commit that directory is the user's call, not this plan's. Ask rather than assume." Both are plan directories sitting untracked in the same repo at the same time; the draft doesn't explain why one gets committed unasked while the other explicitly must not be assumed. An executor would reasonably wonder whether the first clause is also supposed to be an ask-first item that was just phrased as settled by mistake, or whether there's a real reason (e.g., "this plan's directory is new work done *for* this commit, the other isn't") that just isn't written down.

### 5. Section 1 item 4 is a materially incomplete summary of Step 9 — minor

Section 1 ("What gets built"), item 4: "`PROGRESS.md` (at the milestone): remove the 'Known limitation' section and its Outstanding bullet." That's only the first of Step 9's three bullets. Step 9 also adds a new line under the Report entry and adds `20261116000000` to the "Dev-only features not yet ported to prod" list. A reader who only skims Section 1 (which is explicitly framed as "what gets built," i.e., the authoritative inventory) would miss two-thirds of the PROGRESS.md change. Worth making Section 1's item 4 at least gesture at "remove X; add Y" so the two sections don't disagree on scope.

### 6. D6's edit count doesn't match Step 5.3's own diff description — minor/nitpick

D6 says: "The new body is `20261115000000`'s with three edits plus a `NEW` declaration, each marked `-- NEW` or `-- CHANGED`." Step 5.3's diff expectation, a few pages later, lists five distinct regions (the `v_restored` declaration; the shared-keys `if`; the `v_cleared` block; "the NEW restore block"; the update's `data` line) plus the dropped comment tails on two now-stale tags. The restore block in particular is a substantial ~14-line new query, not "a declaration." D6's one-line characterization undersells what's actually changing and doesn't match the more careful Step 5.3 list; a reader who only reads D6 (which is where the "what changed" claim is first made) could be surprised by the size of the actual diff in Step 5.3. Not blocking — Step 5.3's list is the one that's actually checked — but D6 should either match it or just point to Step 5.3 instead of giving its own (smaller) count.

## What's solid

Everything else held up well under a cold read:
- The migration file (Step 1), the two scripts (Steps 2–3), and the verification steps (4–7) are internally consistent with each other — file names, function names, and expected values match everywhere I cross-checked them (e.g., Step 3's expected numbers against the worked example in Section 0.3; the `v_shared_keys` direction-rule change is consistently described in the intro, D1, and the code comment).
- The go-ahead checkpoints (implementation start, Step 6 `db push`, Step 8 `git push`) are stated once at the top and repeated correctly at the matching steps.
- Section 0's ground-truth claims (no backward moves on dev, no `cleared` snapshots yet) are given with the literal query used to verify them, and Step 5.1 re-runs that same query right before the push — good executability, no "trust me" gaps there.
- D1's rejected alternatives, D2's null-snapshot fix, and D3's "same latest-by-seq rule as `report_series`" are each explained with a concrete failure mode and which check in Step 3 would catch it — easy to follow without guessing.

## Summary

Six issues found: two serious (the Step 8/Step 9 ordering contradiction, and the "milestone" labeling ambiguity that caused it), one real completeness gap (no stated path if the user answers "no" to A.1), and three minor/consistency nitpicks (the asymmetric treatment of the two plan directories in Step 8, Section 1's incomplete summary of Step 9, and D6 undercounting its own diff relative to Step 5.3).

The two serious issues are both about the PROGRESS.md/commit sequencing and are easy to fix (just reorder or explicitly state the dependency), but they would genuinely trip up an executor following the steps in order, so I'd want them resolved before this moves to implementation — another draft pass isn't unreasonable, though the fix itself is small (reorder Steps 8/9, or make the milestone-timing explicit, and add one sentence to A.1 about a "no" outcome).
