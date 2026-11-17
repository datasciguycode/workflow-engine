# Round-6 draft review — structure, consistency, executability

Scope: structural/communication lens only (completeness, internal consistency, executability,
ambiguity). I read `round-6-draft.md` in full (not round-5), cross-checked every cross-reference
I could find (decision IDs, step numbers, migration filenames, Section-A item numbers, Step-8
phone-check numbers), and independently recomputed the arithmetic in the Step 4b test fixture by
hand rather than trusting the draft's own stated results.

## Verified as correct / consistent (no issue — stated here so it's clear these were checked, not skipped)

- **`item_requires` semantics are fully specified**, with no guessing required: default when
  absent (D3's table, `private.report_item_requires_valid`'s `p_requires is null -> true`
  branch), behavior on empty array / non-array / JSON null / non-string entries / unknown keys /
  derived-field keys (all enumerated, and each has a matching bad-config test case: lines
  1190–1201). The RPC's `required`/`kept` CTEs (lines 852–865) correctly reduce to "every item
  passes" when `item_requires` is absent (0=0), and I traced the dedup/count logic by hand — it's
  sound.
- **The core correctness property holds and is actually proven by the fixture.** I recomputed
  check 6's numbers from the per-day table at lines 1377–1385 independently: Tue = (40, 40, 20) →
  calories 4·40+4·40+9·20 = 500; Fri = (50, 80, 20) → calories 4·50+4·80+9·20 = 700. Average over
  {Tue, Fri}: protein 45, carbs 60, fat 20, calories 600. And 4·45 + 4·60 + 9·20 = 180+240+180 =
  600 exactly, matching the "calories = 4p+4c+9f of the displayed averages" assertion at lines
  1301–1304. The fixture genuinely exercises the property it claims to, not just by assertion but
  by the underlying data.
- **Step 4b's strip/restore sequencing is coherent and in the right order.** Check 1 (CLI role,
  probing the CHECK) → strip `item_requires` while still CLI role (no role round-trip needed there)
  → become the authenticated user → checks 2–5 run without the gate → check 6 does
  `reset role` → restore the shipped config → `set local role authenticated` → checks 6–10 run
  against the real shipped config. I traced the role transitions line by line (1203–1284,
  1352–1359) and found no gap or ordering error. The "extra round trip" referred to in the prose
  (line 1090) is specifically check 6's `reset role`/`set local role` pair, which would not have
  been needed without the strip — the prose and code agree.
- **"Calories never stored" is stated as settled everywhere it appears**, with no residual
  question anywhere: Section A's "Decided" list (lines 96–98), D10 (line 412), the migration
  comment (line 638), Step 8's commit-message instructions (line 1626), and Section 9 item 2 (line
  1888). I did not find a place where this is still phrased as open.
- **Section A correctly contains only A.1–A.3 as open**, with A.4 and the round-5 "A.4
  interpretation check" both explicitly marked resolved and pointing at where the resolution is
  recorded (D10, Section 9). No stray pending question is hiding elsewhere (Section 4's assumption
  list, which round 5 used for this, has had the item removed, per Section 9 item 6 and confirmed
  by reading Section 4 directly).
- **Section 9's own changelog matches the actual diffs** I could find elsewhere in the document —
  I spot-checked every item against the corresponding section (D3, D10, Step 2, Step 4a, Step 4b,
  Section 4, Section 5, Section 0.3, Section 1, D9, Step 5, Step 8, Step 9, Section 6, Section 7)
  and each one is backed by a real, matching edit. I did not find a leftover calories-only
  reference that was supposed to be updated but wasn't; the "43.75" and "595"/"385" numbers that
  still appear (lines 446–447, 1395–1398, 1937) are deliberately kept as regression-naming
  context in FAIL messages and history, not stale assertions.
- The 27→33 validator case count checks out: I counted the array literal at lines 1148–1201 by
  hand — 27 pre-existing cases plus exactly 6 new `item_requires` cases.

## Issues found

1. **The "Numbering note" (lines 35–38) mischaracterizes A.4 and the "A.4 interpretation check."**
   It says: *"Removed items stay as one-line tombstones: D4, Step 3, A.4 (now resolved), the A.4
   interpretation check (resolved in round 6) and Step 8 check 4.5."* D4, Step 3, and Step 8 check
   4.5 are indeed literal one-line tombstones (`(Removed: goals.)`, `(Removed: the report_goals
   migration.)`, `(Removed: Weight card check.)`). But A.4 (lines 80–89) is a ten-line, multi-
   sentence resolved explanation, not removed and not one line; the "A.4 interpretation check"
   section (lines 90–93) is similarly a short paragraph, not a one-liner, and nothing was
   "removed" there either — the content was answered, not deleted. Grouping these with the true
   tombstones under "Removed items... stay as one-line tombstones" is inaccurate and could mislead
   a reader skimming the numbering note into expecting one-line stubs at A.4, when in fact there's
   substantive content to read. This looks like a leftover from reusing the round-5 template
   language without adjusting it for round 6's different treatment of A.4. Minor, but worth a
   one-sentence fix (e.g., split into "literal one-line tombstones: D4, Step 3, Step 8 check 4.5"
   and "resolved, kept as full explanations: A.4, the A.4 interpretation check").

2. **Minor fragility (not a correctness bug, but worth flagging for whoever executes Step 4b):**
   the SETUP guard at lines 1127–1129 compares `item_requires` for strict JSON equality against a
   literal `'["protein_g", "carbs_g", "fat_g"]'::jsonb`, which is order- and whitespace-sensitive
   even though the config's semantics don't care about array order. As written in Step 2 the
   shipped config does use exactly that order, so the guard will pass as specified — this isn't a
   contradiction in the plan — but it's a sharp edge that would produce a confusing SETUP failure
   (rather than a real test failure) if a future edit to the Nutrition config ever reorders that
   array. Worth a one-line comment in the script if the authors want to head that off, not a
   blocking issue for this round.

## Items outside this lens (noted but not pursued, per my mandate)

The Section A judgment call about keeping the week stepper despite "nothing else" (page scope,
line 107–112) and the engineering tradeoffs in D10's rejected alternatives are *reasoned* and
*internally consistent*, but whether they're the *right* calls is the sanity-check agent's
territory, not mine.

## Verdict

I found one real but minor communication inconsistency (the numbering-note mischaracterization of
A.4) and one minor fragility worth a comment but not a fix. Everything else I checked — the
precision of `item_requires`'s specification, the correctness-by-construction of the test fixture
(verified by independent arithmetic, not just trusting the draft), the coherence and ordering of
the Step 4b strip/restore sequence, the "never stored" consistency, Section A's scope, and the
Section 9 changelog's accuracy against the rest of the document — held up under direct
cross-checking with no gaps, contradictions, or places where an implementer would have to guess.

**This draft does not need another full revision round on structural/communication grounds.** It
is ready to advance to final architect review. The two items above are cheap, optional polish (a
one-sentence fix to the numbering note, and perhaps a comment on the SETUP guard's strictness) —
neither blocks moving forward, and neither affects what gets built.
