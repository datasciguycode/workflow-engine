# Round 1 review notes — structure, consistency, executability

Reviewed against the actual codebase: `CLAUDE.md`, `PROGRESS.md`, `.github/workflows/deploy-pages.yml`,
`web/wwwroot/index.html`, `web/wwwroot/404.html`, `web/wwwroot/manifest.webmanifest`,
`web/Services/WorkflowApiClient.cs`, `web/Services/AuthState.cs`, `supabase/migrations/*.sql`,
`supabase/config.toml`, `supabase/seed.sql`, `supabase/functions/agent-loop/index.ts`, and
`supabase/.gitignore`. This pass is about structure/communication (completeness, internal
consistency, ambiguity, executability), not technical correctness — that's the sanity-checker's
independent lens. Where I could, I cross-checked specific factual claims against the repo (file
contents, line numbers, migration count, table names, grants, CORS headers) and they all check out
— the plan is unusually well-grounded in the actual code rather than guessed. One CLI-flag claim
(`supabase secrets set --env-file`) was verified against Supabase's own docs and is correct.

## Issues found

1. **"All must pass" checklist header contradicts items inside it marked optional/skippable.**
   The Verification checklist is introduced with "**all must pass before calling prod live**", but
   at least two items inside it are explicitly conditional:
   - "Shared-origin coexistence (D1)" ends with "Skip it if the user prefers zero dev contact today,
     but do it before relying on side-by-side use."
   - "Cross-project, prod token against dev" is tagged
     `[OPTIONAL, READ-ONLY DEV TOUCH, NEEDS USER OK]`.
   An executor following the header literally would block on these; following the inline text, they
   wouldn't. The header should say something like "all required items must pass; optional/dev-touch
   items are called out individually," or the optional items should be pulled into a clearly
   separate "nice to have" sub-list. As written it's a direct contradiction a literal reader has to
   resolve by guessing which instruction wins.

2. **Mislabeled cross-reference: "Step 7's curl check" doesn't exist in Step 7.**
   Assumption A2 says: *"If a project created in Nov 2026 lacks `SUPABASE_ANON_KEY`, `agent-loop`
   would send `apikey: undefined` and every REST call would 401. **Step 7's curl check** catches
   this."* But Step 7 ("Deploy `agent-loop` and set its secret") contains a `supabase secrets list`
   check for `SUPABASE_ANON_KEY`, not a curl check — the actual curl check lives in the Verification
   checklist's "Agent chat → Direct call before the UI" item. Someone reading A2 and then going to
   Step 7 looking for "the curl check" won't find one; they'll find a different (also valid) check,
   and may wonder if they're missing a step. Minor, but it's a dangling pointer between two sections
   that should name the same thing.

3. **A2 fallback doesn't say to redeploy after editing the source.**
   The A2 fallback ("Risks and edge cases") says to edit line 25 of `agent-loop/index.ts` in the prod
   repo. It never states the obvious-but-necessary follow-up: re-run
   `supabase functions deploy agent-loop --project-ref <PROD_REF>` for the edit to take effect. Every
   other code-edit-then-deploy sequence in the plan (Step 5 → Step 6/7) spells out the deploy step
   explicitly; this one, buried in Risks rather than the main step sequence, doesn't. Someone
   executing the fallback mid-Step-7 could edit the file and move on without redeploying, and the
   original symptom (401s) would persist with no further guidance pointing back at this gap.

4. **Ambiguous instruction: "In `web/wwwroot/index.html`, set `<title>`." — to what?**
   Step 5.3 (2): the manifest change gives a concrete example ("e.g. `Workflow Engine`"), but the
   `index.html` `<title>` change gives no target value at all. The reader has to invent a value and
   guess whether it should match the manifest's name, something else distinguishing it from dev's
   "WorkflowApp.Web", or something else entirely. Low stakes, but it's the one blank the plan leaves
   genuinely unfilled where a parallel instruction two lines above fills it in.

5. **User-decision points aren't signaled with one consistent convention.**
   The plan uses a clear, greppable marker — `[OPTIONAL, READ-ONLY DEV TOUCH, NEEDS USER OK]` — for
   points that touch dev. But several other places that also need a stop-and-ask-the-user moment
   before proceeding are only described in surrounding prose, with no equivalent marker:
   - D3: "Decision for the user, not made here" (free vs. Pro / same org vs. new org) — needed before
     Step 2's `--org-id` is chosen.
   - D5 / Step 5.4: "Which workflows go in: this needs user confirmation" and the account
     name/workflow list, checklist values if the optional dev read is skipped.
   - A6 / D2: the repo name itself ("provisional; user may prefer another").
   An executor skimming for "where do I need to stop and check with the user" will reliably catch
   the bracketed dev-touch items (since those are visually consistent) but has to read the whole
   document closely to catch the others, since they're phrased differently each time. Worth
   unifying under one marker (or at least one bolded lead-in phrase) so a single grep/skim catches
   every stop point.

6. **`add_member.sql` is a template with literal placeholders; the plan never says how to fill it in before running.**
   Step 5.5 defines `supabase/prod/add_member.sql` with placeholders `<new-uuid-A>`, `<owner|member>`,
   `<email>`, `<display name>`. Step 8.3 says "Run `add_member.sql` with the owner's email and
   `role='owner'`" but never states the mechanism: edit the file in place before each run (and revert
   after?), copy it to a scratch file per invocation, or pass values some other way (the file as
   shown has no `psql` variable substitution, e.g. no `:email` placeholders usable with `-v`). Since
   this file will be run repeatedly for each new member (Step 8.4), an executor has to invent their
   own convention for "how do I parameterize this file today" — a real gap for a step that's meant to
   recur.

## What's solid

- Every concrete factual claim I could check against the repo was accurate: the 12 migrations and
  their names/order, the table list and exact grants (`20261101000000` and `20261104000000`), the
  `mcp-server` `verify_jwt = false` config and the "don't deploy it by accident" warning, line 25 of
  `agent-loop/index.ts`, the CORS `*` header, the `pathSegmentsToKeep = 1` / single-path-segment
  404.html logic (which does generalize correctly to any one-segment repo name), the `AuthState.cs`
  `StorageKey` constant and shared-origin reasoning, the seed.sql workflow/stage IDs and titles for
  "Joe's Auto Repair," and the `supabase/.gitignore` entry for `.env`.
- Step ordering is internally consistent on the one dependency that matters most: the Supabase
  project (Step 2) is created before the code edits that hardcode its ref/key (Step 5), which are
  committed before the first push (Step 6) — so D8's stated hard requirement ("first push must
  already contain prod config") is actually honored by the step sequence, not just asserted.
- The hard constraint (never touch dev) is upheld consistently throughout: every dev-adjacent
  action is either explicitly read-only-and-flagged, or has a stated no-touch fallback, and the
  final verification section includes a concrete check that dev's own git/link state is unchanged.
- Rollback and out-of-scope sections are unambiguous and don't contradict anything earlier in the
  document.

## Verdict

Six issues, all minor-to-moderate — none are "the plan is wrong" findings (that's the
sanity-checker's lens), and none block starting execution. But two of them (#1 the contradictory
"all must pass" header, and #5 the inconsistent signaling of stop-and-ask-the-user points) are the
kind of thing that would cause a real executor to either stall on an ambiguous instruction or blow
past a point where they should have paused for user input — which matters a lot given this plan's
whole premise is "don't do anything irreversible without the user's sign-off." I'd fix at least
those two (and ideally #3 and #6, which are small additions) before calling this ready to execute
unattended. None of this requires a structural rewrite — a light editing pass over the existing
draft would resolve all six. I'd call this "needs one more light revision," not "needs another full
draft round."
