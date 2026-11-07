# Round 2 review notes — structure, consistency, executability

Reviewed `round-2-draft.md` against `round-1-review-notes.md` and `round-1-sanity-check.md` (to
confirm every finding from both was actually resolved, not just asserted as resolved), and against
the real codebase: `CLAUDE.md`, `PROGRESS.md`, `.github/workflows/deploy-pages.yml`,
`web/wwwroot/index.html`, `web/Services/WorkflowApiClient.cs`, `web/Services/AuthState.cs`,
`supabase/migrations/*.sql` (all 12), and `supabase/functions/agent-loop/index.ts`. This pass is
about structure/communication (completeness, internal consistency, ambiguity, executability), not
technical correctness — that's the sanity-checker's independent lens, and I'm not duplicating it.

## Round 1 feedback: confirmed actually resolved

I checked each of round 1's findings against the new text rather than taking the draft's own
"Feedback from this round" section at its word:

- **Plan-reviewer #1 (contradictory "all must pass" header):** fixed. The checklist is now split
  into **Required** and **Recommended**, each item under Recommended states its own skip
  consequence, and the D1 coexistence test and cross-project token test (plus its converse) moved
  there. No remaining "all must pass" language anywhere that contradicts an inline "optional."
- **Plan-reviewer #2 (dangling "Step 7's curl check" reference):** fixed. A2 now names both real
  checks by their actual location ("Step 7's `supabase secrets list` check" and "the Verification
  checklist's 'Agent chat: direct call before the UI' curl check"), and both exist exactly where
  claimed.
- **Plan-reviewer #3 (A2 fallback missing the redeploy):** fixed. The Risks "A2 fallback" is now a
  numbered sequence (edit → **redeploy** `agent-loop` → re-run curl check → commit + record), and
  Step 7 separately says "including its redeploy" when pointing back at it.
- **Plan-reviewer #4 (no target value for `<title>`):** fixed. Step 5.3 gives a concrete value
  (`Workflow Engine`), matching the manifest change above it, and notes the current value
  (`WorkflowApp.Web`) for contrast.
- **Plan-reviewer #5 (inconsistent decision markers):** fixed, with one small gap — see new issue
  #1 below.
- **Plan-reviewer #6 (`add_member.sql` fill mechanism undefined):** fixed. It's now a
  never-edited-in-place template with named placeholders (`__EMAIL__`/`__ROLE__`/`__DISPLAY_NAME__`),
  a documented sed fill → leftover-token grep → run → delete sequence, and a stated escaping
  caveat for apostrophes/slashes/ampersands in names.
- **Sanity-check #1 (`buildCheckDone` same-tab collision):** addressed with a different, arguably
  better fix than either option it offered — a distinct `buildCheckDone-prod` key — with the
  reasoning for rejecting the build-id-keyed alternative spelled out (it would still let prod
  suppress dev's check, and dev can't be touched today).
- **Sanity-check #2 (bootstrap.sql "idempotent" conflation):** addressed. `accounts` stays
  `do nothing`; `workflows`/`stages` become `on conflict (id) do update set ...`, and the new
  limitation (no deletes, unique-constraint traps on title swaps / `is_initial` moves) is spelled
  out in three places (D5 prose, the SQL file's own header comment, and Risks).
- **Sanity-check #3 (unverified nonce claim):** addressed as A7, written with the same
  verified/assumed/trigger-symptom structure as A1-A6.
- **Sanity-check #4 (no action needed):** correctly left as-is.

All ten prior findings are genuinely resolved, not just claimed-resolved. I also independently
re-verified several of the plan's concrete factual claims against the current file contents: the
`buildCheckDone` get/set lines are still exactly lines 42-43 of `index.html`; `AuthState.StorageKey`
is still the literal string `"workflow-app.auth-session"` at line 16; `SUPABASE_ANON_KEY` is still
read at line 25 of `agent-loop/index.ts`; the migrations directory still contains exactly 12 files
matching the names the plan cites; and the dev `SupabaseConfig.ApiUrl`/`PublishableKey` values the
plan says must not leak into prod match what's actually hardcoded in `WorkflowApiClient.cs` today.

## New issues in round 2

1. **The "U6" label in the decision table is never used where it's needed.** The "User decision
   points" table (around line 37) bundles four separate dev-touch items under one ID, "U6":
   dev checklist read (D5), schema-dump diff (A3), and the two Recommended verification items. But
   none of those four spots in the body actually say "U6" — they're each tagged only with the
   generic `[USER DECISION: optional read-only dev touch]` marker (lines 207, 288, 609). Every
   *other* row in that table (U1-U5, U7, U8) does have its exact ID appear inline at its point of
   use, so U6 is the one exception to a pattern the plan otherwise follows consistently. The
   document's own greppability claim ("`grep -n "USER DECISION"` finds all of them," line 28) still
   holds, since the generic marker is itself a form of `USER DECISION`, so nothing is actually
   lost — but anyone who tries to jump straight to "U6" the way the table's numbering invites will
   find nothing by that name. A one-word fix (append ", U6" to each of the four markers) would
   close this.

2. **Minor incompleteness in the same table's "Needed before" column for U1.** It says the repo
   name decision is "Needed before Step 2 (it becomes the URL used in Steps 4-6)." In fact it's
   also baked into the `<PROD_URL>` placeholder definition before Step 1, into Step 8 ("the owner
   opens `<PROD_URL>`"), and into most of the Verification checklist. Not wrong, just an
   undercount of how far the decision's blast radius actually reaches — a reader skimming the
   table for "where does this matter" could be misled into thinking it's done mattering after
   Step 6.

3. **"Independently-owned" repo, as stated in the task, is resolved by implication rather than by
   an explicit, tagged decision.** The task this plan is answering calls for "a new,
   independently-owned GitHub repo." The plan creates the new repo under the *same* GitHub account
   as dev (`gh repo create datasciguycode/workflow-engine-prod`, D2 and Step 6), which is a
   reasonable reading of "independently-owned" as "a repo independent of dev's repo" rather than
   "owned by a different account" — but the plan never says so. Every other judgment call of
   comparable weight in this document gets a `[USER DECISION: ...]` tag or at least a one-line
   "here's the reading I chose and why" (see A1-A7, D2's own repo-*name* decision two lines away).
   This one reading of the word "independently" just isn't addressed at all, tagged or not. Low
   severity — nothing about it is irreversible, dev-touching, or hard to change later (a repo can
   be transferred to another GitHub account after the fact) — but it's the one place in an
   otherwise exhaustively self-aware plan where a stated requirement from the brief goes unmentioned
   rather than explicitly resolved.

4. **One small unstated assumption in an otherwise fully explicit command sequence.** Step 1 clones
   the dev repo and Step 6 later runs `git push -u origin main`, but nothing in Step 1 confirms the
   clone's default branch is actually `main` (it will be, since that's dev's default branch, but
   the plan states CLI flags and exact expected outputs for nearly everything else — e.g. "expect
   all 12 migrations listed," "`cat supabase/.temp/project-ref` must print `<PROD_REF>`" — and this
   is the one place a `git branch` sanity check would fit the plan's own established level of
   explicitness but isn't there).

## What's solid (round 2 specifically)

- The Required/Recommended verification split is now unambiguous and internally consistent: every
  item under Recommended states what "skipping" costs, and nothing under Required secretly depends
  on a dev touch.
- Cross-references between sections (A2 ↔ Step 7 ↔ Verification; D5 ↔ bootstrap.sql's own header
  ↔ Risks; Step 5.5 ↔ Step 8.3's "using the sed fill-and-run block in Step 5.5") all point to real,
  matching content — I checked each by locating both ends, not just by reading the claim on one
  end.
- The "Facts established while writing this" section is a good structural addition: it cleanly
  separates verified-from-the-repo facts from the Assumptions section's genuinely unverifiable
  claims, and nothing in it contradicts anything stated later in Key decisions or Steps.
- Step ordering still honors the one dependency that matters most (Supabase project before the
  code edits that hardcode its ref/key, committed before the first push), and D8 states this
  explicitly rather than leaving it implicit.

## Verdict

Four issues, all minor, none blocking. Three are cosmetic/communication nits (#1, #2, #4) that a
light copyedit would fix in minutes. #3 is the only one worth a deliberate decision rather than a
copyedit — but it's a disclosure gap (the plan should say what it assumed and why), not a safety or
correctness gap: the chosen reading doesn't put dev at risk, doesn't ship anything wrong, and is
easily revisited later if the user actually wanted a separate account. All ten issues raised by the
round-1 plan-reviewer and sanity-check passes are genuinely resolved, not just asserted as resolved.

**This plan does not need another full draft round.** It's ready to advance as-is, or with a
one-pass copyedit for #1, #2, and #4, plus either a one-line acknowledgment of the "independently-
owned" reading (#3) or an explicit confirmation from the user that same-account is fine before
Step 6 runs.
