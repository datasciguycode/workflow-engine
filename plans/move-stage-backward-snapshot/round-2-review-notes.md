# Review notes — round-2-draft.md (move_stage backward-move snapshot/restore fix)

Reviewed cold, as the engineer who would execute this plan, against `round-1-draft.md`,
`round-1-review-notes.md`, `round-1-sanity-check.md`, `plans/generic-report-feature/final-plan.md`,
`CLAUDE.md`, and the current `PROGRESS.md`. Findings are about structure, sequencing, and
communication — not SQL correctness (the sanity-check agent's lane).

## Round-1 fixes: verified, not just claimed

- **Step 8/Step 9 step-ordering contradiction.** Actually fixed. Step 8 now states outright
  "**Does not include `PROGRESS.md`**" and explains why (CLAUDE.md, Report-plan precedent). Step 9
  is retitled "carry-forward for the next user-invoked milestone (**not an action of this plan**)"
  and says explicitly "Nothing in Steps 1–8 depends on this, and no step of this plan edits
  `PROGRESS.md`." The numbering no longer implies Step 9 runs between drafting and the commit.
  Section 1 item 4 was reworded to match ("not edited by this plan... Step 9 lists what to carry
  into it then"). This closes the contradiction cleanly — confirmed by cross-reading Step 8, Step 9,
  and Section 1 item 4 together; none of the three disagree anymore.
- **A.1's missing "if declined" path.** Actually fixed. A.1 now has a concrete "**If you decline**"
  branch: record "declined" and stop, then offer (a) clear-without-restore, (c-alt) refuse backward
  moves, or leave as is, restating each one's cost, then re-plan the chosen option as a new round.
  This gives an executor a real next action instead of silence. (See new issue #1 below, though —
  the wording around how many options are offered doesn't quite add up.)
- **Section 1 item 4's incomplete PROGRESS.md summary.** Partially fixed, not fully — see issue #2
  below. It now lists three of Step 9's four bullets, still dropping the fourth ("Record A.1's
  answer").
- **D6 undercounting the diff relative to Step 5.3.** Actually fixed. D6 now lists the same five
  regions Step 5.3's `diff` comment expects, plus the two dropped comment tails, in the same order
  and wording. Cross-checked line-by-line against Step 5.3's "expect ONLY" comment — they now match.
- **Plan-directory commit asymmetry.** Actually fixed, and settled rather than just explained. Step
  8 now defaults to committing *both* untracked plan directories, asks one combined question
  covering both ("I'll commit both plan directories... OK, or leave either out?"), and gives a
  concrete fallback (a second commit) if the user wants `plans/generic-report-feature/` split out.
  The go-ahead list in Section A was updated to include this ask. No remaining inconsistency between
  how the two directories are treated.

## New issues in round 2

### 1. A.1's decline path says "two remaining options" but lists three — ambiguity

Section A.1, "If you decline," step 2:

> asks which of the **two** remaining options you want, restating the cost of each from D1:
> - **(a)** clear + snapshot on backward moves, no restore. …
> - **(c-alt)** refuse backward moves …
> - Or **leave it as is** (the "Known limitation" stays in `PROGRESS.md`).

That's three bulleted choices following a sentence that says "two." If "leave it as is" is meant to
be a non-replanned fallback rather than a third real "option" (consistent with step 3's "**Either**
option reuses most of this plan," which only makes sense for (a) and (c-alt)), the text should say
so — e.g., "two re-plannable options, or leave it as is." As written, an executor reading step 2 in
isolation will count three choices against a stated total of two and have to guess which one isn't
"really" an option. Easy fix: change "two" to "three," or explicitly separate "leave it as is" from
the "two options" sentence.

### 2. Section 1 item 4 still omits one of Step 9's four bullets — minor, residual from round 1

Round 1's issue 5 flagged that Section 1 item 4 summarized only one of Step 9's bullets. Round 2's
fix added the other two substantive bullets (the Report-entry note, the dev-only list) but still
drops the fourth: Step 9's last bullet, "Record A.1's answer." Section 1 item 4 (quoted in full):

> `PROGRESS.md`: not edited by this plan. … Step 9 lists what to carry into it then: remove the
> "Known limitation" section and its Outstanding bullet; add a one-line … note …; add
> `20261116000000` to the dev-only/not-yet-ported list.

Step 9 itself has a fourth bullet not mentioned here: "Record A.1's answer." Since Section 1 is
framed as the authoritative "what gets built" inventory, a reader who trusts it over Step 9 would
still miss a quarter of the carry-forward list. Low stakes (it's a one-line addition to a future
milestone), but the round-1 finding wasn't fully closed, just narrowed.

### 3. The round-1 sanity-check's four findings are addressed selectively, with no stated disposition for two of them — completeness gap in the "Feedback from this round" section

The draft's closing "Feedback from this round" section explicitly answers two of the sanity-check's
four findings (the `item_agg: last` comment placement, and the re-check/push gap), and then says:

> **Not reworked (both reviews said they held up):** the restore-on-both-directions design (D1),
> the literal migration SQL, the snapshot format (D2), Section 0's ground-truth queries, both check
> scripts, Step 4–7 gates.

That list doesn't actually cover the sanity-check's finding #1 (factor the shared "latest cleared
value" lookup out of `move_stage` and `report_series` into one function, so D3's invariant can't
silently drift) or finding #4 (D5 eliminates data *loss* but not the secondary "no documented basis
for the agent to proactively flag a value surprise" effect). Both were explicitly labeled
"worth considering," not blocking, in round 1 — so skipping them is defensible on the merits — but
the round-2 draft doesn't say it's skipping them; it just doesn't mention them, while using language
("both reviews said they held up") that reads as if everything from both round-1 reviews was
accounted for. An executor diffing round-1-sanity-check.md against this section would notice two
findings silently vanished. A one-line "sanity findings 1 and 4 are left for a future pass, both
non-blocking" would close this cleanly.

## What's solid

- The go-ahead checkpoint list in Section A now has four items (start, Step 6 push, Step 8 commit,
  Step 8 push) and each is restated correctly at its matching step — consistent throughout.
- The migration file, both scripts, and Steps 4–7's gates are unchanged from round 1 apart from the
  added header-comment note, and that note is correctly cross-referenced from Section 5 and from the
  Step 4 "already done while drafting" bullet.
- Section 0's ground-truth claims are still backed by literal queries, re-run pre-push (5.1), with
  added language (new in round 2) that correctly describes the re-check as narrowing, not closing,
  the race window — this reads as a genuine, not cosmetic, response to the round-1 sanity-check note.
- No new file-name/function-name mismatches found across Steps 1–9, D1–D6, and Sections 4–6 on this
  pass.

## Summary

Three issues found, all minor/ambiguity-level (no "serious" findings this round): a counting
mismatch in A.1's decline-path wording ("two" vs. three listed choices), a residual
(not-fully-closed) gap in Section 1 item 4's PROGRESS.md summary, and a completeness gap in how the
"Feedback from this round" section accounts for the round-1 sanity-check's four findings (two are
addressed, two silently drop out with no stated disposition). All four round-1 plan-reviewer issues
(step-ordering contradiction, A.1 fallback, PROGRESS.md summary, D6/Step-5.3 consistency, and the
plan-directory commit asymmetry) were genuinely fixed, not just claimed fixed, with one exception
(item 2 above, partially fixed). None of this round's findings are serious enough on their own to
require another full draft before building; they're all one- or two-sentence wording fixes. If the
author wants a clean slate, folding in these three plus whatever the parallel sanity-check pass
turns up for round 2 would be the efficient path, but nothing here blocks moving forward.
