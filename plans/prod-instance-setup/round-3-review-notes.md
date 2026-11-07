# Round 3 review notes — structure, consistency, executability

Reviewed `round-3-draft.md` against `round-2-review-notes.md` (round 2's plan-reviewer findings)
and round 3's own "Feedback from this round" section (which is where round 2's sanity-check
findings are recorded and answered, since no standalone `round-2-sanity-check.md` file exists in
this repo — round 3 relays and resolves them inline instead). Also re-read the plan cold against
the real codebase: `CLAUDE.md`, `PROGRESS.md`, `.github/workflows/deploy-pages.yml`,
`web/wwwroot/index.html`, `web/Services/WorkflowApiClient.cs`, `web/Services/AuthState.cs`,
`supabase/config.toml`, all 12 files in `supabase/migrations/`, `supabase/functions/agent-loop/index.ts`,
`supabase/functions/mcp-server` (existence), `web/wwwroot/manifest.webmanifest`, and
`supabase/.gitignore`. As before, this pass is about completeness/consistency/ambiguity/
executability, not technical correctness — that's the sanity-checker's independent lens.

## Round 2 plan-reviewer findings: confirmed actually resolved, not just asserted

I checked each against the live text and the round 3 "Feedback from this round" claims, rather
than trusting the draft's own account:

- **#1, "U6" never appears inline.** Fixed and verified at all four points of use: D5 Option A
  (line ~247, `[USER DECISION: optional read-only dev touch, U6]`), A3's stronger schema-dump
  check (line ~332, same tag), and both Recommended verification items ("Shared-origin
  coexistence (D1), U6" and "Cross-project, prod token against dev, U6"). The decision table's U6
  row correctly describes these as "four separate yes/no calls."
- **#2, U1's reach understated in the table.** Fixed. The U1 table row now explicitly lists
  `<PROD_URL>`/base path, Step 4, Step 5, Step 6, Step 8, and "most of the Verification checklist."
- **#3, "independently-owned" reading never stated.** Fixed. D2 now states the chosen reading
  (independent of dev's repo, not independent of dev's GitHub account) explicitly, names the
  alternative reading, and notes the consequence of the alternative (different `*.github.io`
  origin, which would remove D1's storage collision). U1's table row and A6 both point at this.
- **#4, no default-branch check.** Fixed. Step 1 now runs `git branch --show-current` with an
  explicit expected value (`main`), and "Facts established" records the `git ls-remote --symref`
  check that justifies expecting `main`.

All four are genuinely resolved in the text, not just claimed resolved in the "Feedback from this
round" section.

## Round 2 sanity-check findings (relayed via round 3's own "Feedback from this round," items 1-4):
confirmed resolved

Spot-checked each against the actual codebase rather than trusting the draft:

1. **Shared `project_id` / `--use-api`.** `supabase/config.toml` line 5 is in fact
   `project_id = "workflow-app"`, confirming the problem being fixed is real. Step 1 now renames it
   to `workflow-app-prod` and commits before any other `supabase` command; `--use-api` appears on
   every `functions deploy` invocation in the document (D7, Step 7, the A2 fallback's redeploy).
2. **`--skip-vault`.** Both `supabase db push` invocations in Step 3 (dry-run and real) now carry
   `--skip-vault`. `supabase/config.toml` does have `[db.vault]` commented out, consistent with the
   plan's own "currently a no-op, but belt-and-suspenders" framing.
3. **A2 fallback as concrete code.** The Risks "A2 fallback" section now gives an actual property-
   access expression instead of pseudocode, and line 25 of `agent-loop/index.ts` is in fact
   `const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;`, matching what the plan says it's
   patching.
4. **Implicit vs. PKCE flow assumption.** Now an explicit sub-bullet of A7 with a stated symptom
   (`?code=` with no session) and a pointer from Step 8.2.

All four check out.

## New issue found in round 3

1. **A4 ("Data API defaults") is the one assumption left orphaned — it describes a UI path the
   plan's own Step 2 doesn't take.** A4 reads: "If the creation flow offers 'automatically expose
   new tables' or a Data API toggle, keep the Data API on." But Step 2 creates the project
   exclusively via CLI (`supabase projects create workflow-engine-prod --org-id ... --region ...
   --db-password ...`) — there's no dashboard "creation flow" with a toggle anywhere in this plan's
   actual command sequence. Every other assumption in the list is explicitly tied to a place the
   plan would notice or act on it: A1 "the fallback is in Step 6," A2 "two checks catch this... the
   fallback edit is in Risks," A3 "verification exercises every RPC... a stronger check [is] run
   from the prod clone," A6 points at D2/U1, A7 "Step 8.2's first sign-in" and "how either would show
   up." A4 is the sole exception — a conditional ("if the creation flow offers...") whose premise
   doesn't match the plan's own mechanism, with no step cross-reference and no stated consequence if
   skipped. Low severity (the plan's own last sentence says exposure-by-default doesn't matter
   because migrations grant explicitly, so nothing breaks either way) — but it's dead text as
   written: someone executing exactly the CLI commands given will never encounter the toggle being
   described, so it is neither actionable nor safely ignorable as stated.

## What's solid (round 3 specifically)

- Every forward/backward cross-reference I traced actually resolves to real, matching content:
  U1-U8 all appear inline at every point of use the table promises; D1's storage-key changes match
  exactly what Step 5.2 edits and what the Verification checklist checks; D5's re-run semantics
  match the SQL header comment and the Risks entry word-for-word in substance.
- Independently re-verified several of the plan's own factual claims rather than trusting them:
  `supabase/.gitignore` does ignore `.env` under `supabase/`; `supabase/functions/mcp-server`
  exists with `verify_jwt = false` in config.toml as claimed; all 12 named migration files exist
  under exactly those names; `web/wwwroot/manifest.webmanifest`'s current `name`/`short_name` is
  "WorkflowApp.Web" as the plan assumes it's changing from; `deploy-pages.yml`'s permissions block
  indeed lacks `administration:write`, supporting D8's claim about why `configure-pages@v6`'s
  default `enablement: false` needs an explicit `gh api` workaround.
- Live-machine facts the plan asserts are true right now: dev's `supabase/.temp/project-ref`
  contains `utwyvtbzesswpoihmlic`; dev's git status shows only the untracked
  `plans/prod-instance-setup/` directory; dev's local Docker stack is running under exactly the
  `supabase_*_workflow-app` container names the plan names throughout.
- The Required/Recommended verification split, the D1 fix, the A2/A7 fallback structures, and the
  bootstrap.sql re-run semantics — all carried over from round 2 — remain internally consistent
  under round 3's edits; nothing introduced this round contradicts them.

## Verdict

One new issue, minor and cosmetic (A4 is orphaned/dead text, not a safety or correctness gap — by
the plan's own admission the outcome doesn't matter either way). All eight prior findings (four
plan-reviewer, four sanity-check) are genuinely resolved, not just asserted as resolved, confirmed
against both the document text and the live codebase/machine state where checkable.

**This plan does not need another draft round.** It's ready to execute as written. A one-line fix
to A4 (either delete it, since the CLI path makes it moot, or rewrite it to say "N/A — this plan
creates the project via CLI, which has no such toggle; not relevant here") would tidy the one loose
end, but nothing blocks starting Step 1 without it.
