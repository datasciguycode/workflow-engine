# Sanity-check findings: prod-instance-setup round-1-draft.md

Reviewed: `plans/prod-instance-setup/round-1-draft.md`, `CLAUDE.md`, `PROGRESS.md`,
`.github/workflows/deploy-pages.yml`, `web/wwwroot/index.html`, `web/wwwroot/404.html`,
`web/Services/WorkflowApiClient.cs`, `web/Services/AuthState.cs`, `supabase/config.toml`, all
`supabase/migrations/*.sql`, `supabase/functions/agent-loop/index.ts`. Also verified actual
installed Supabase CLI v2.120.0 flag behavior (`projects create`, `db push`, `db query`,
`link`, `functions deploy/list/delete`, `secrets set/list`) against the live `--help` output
rather than assuming, and checked current web sources on Supabase free-tier limits/pause and
`actions/configure-pages` enablement defaults.

## Must address before implementation

None. I adversarially checked every Supabase CLI invocation in the plan against the installed
CLI's actual `--help` output, and every one is syntactically correct and does what the plan
says (`--dry-run` and `--include-seed` really exist on `db push`; `functions deploy <name>`
really deploys only that function, confirming the `mcp-server` danger the plan calls out is
real and correctly mitigated; `db query --project-ref` and `secrets set --env-file` are real).
I also checked the GitHub Pages / `actions/configure-pages@v6` mechanics the plan is unsure
about (A1): `configure-pages@v6`'s `enablement` input now defaults to `false` and even when
`true` needs a token with `administration:write`, which the workflow's `GITHUB_TOKEN`
permissions (`contents: read, pages: write, id-token: write`) don't grant — so the plan's
explicit `gh api POST .../pages` step before the first push is in fact necessary, not
redundant, and its fallback-after-422 plan is sound. I found nothing that risks touching dev —
the directory separation, `--project-ref` discipline, disabled push URL on `dev-upstream`, and
avoidance of `supabase config push` and `--include-seed` are all correct and address real
failure modes (verified `config.toml`'s `[auth] site_url = "http://127.0.0.1:3000"`, which
really would get pushed to prod's auth settings by a bare `config push` — good catch by the
plan). Nothing here blocks moving forward.

## Worth considering

1. **(Critique) D1's "not a concern" claim about `buildCheckDone`/sessionStorage is
   incomplete.** The plan correctly identifies the real localStorage collision (shared
   github.io origin) and fixes it by changing `AuthState.StorageKey`. But it dismisses the
   `sessionStorage` build-id-reload flag in `index.html` as safe because sessionStorage is
   "scoped to a single tab." That's true across *separate* tabs, but sessionStorage is scoped
   per-origin-per-tab, not per-site — if the owner visits dev, then navigates to the prod URL
   in the *same tab* (same origin, same tab, just a different path), `buildCheckDone` is
   already `"1"` from the dev visit, so prod's one-time forced-reload-on-stale-build check
   (added 2026-11-06 specifically to kill "recurring stale-cache complaints on iOS") will
   silently never fire on that tab. This reintroduces exactly the bug class that mechanism
   exists to prevent, for whichever of the two sites is visited second in a tab. Low-severity
   (only affects the owner's/admin's own cache-busting, not data safety, and the plan's own
   verification step happens to use two separate tabs), but the "not a concern" framing is
   wrong as stated. Fix: either note the caveat explicitly, or make the flag build-id-specific
   (store the last-seen build id instead of a flat boolean) so it isn't fooled by a different
   site's build id under the same origin.

2. **(Critique) D5's bootstrap.sql "idempotent" framing conflates two different things.**
   `on conflict (id) do nothing` makes the script *safe to re-run without erroring*, but it
   does not make edits idempotent: if the account name, workflow fields, or a stage's
   `checklist` value is tweaked later and the file is re-applied, the `do nothing` clause
   means the edit silently has no effect on already-inserted rows — there's no error, no row
   change, nothing to signal "this didn't take." Someone revisiting this file weeks later to
   fix a checklist typo could reasonably expect a rerun to apply the fix and be surprised when
   it doesn't. Fix: either call out this limitation explicitly next to "idempotent," or switch
   to `on conflict (id) do update set ...` for the mutable columns (title/checklist/name) while
   keeping `do nothing` only on `accounts` (which genuinely should never be touched again by
   this file).

3. **(Alternative, minor) D6's "Skip nonce check off... the implicit flow via /authorize
   doesn't need it" is asserted without the same "verify, don't assume" treatment the plan
   gives everything else (A1–A6).** It's probably fine either way (nonce checking matters for
   `signInWithIdToken`/native flows, not the hosted `/authorize` redirect flow this app uses),
   but given the plan is otherwise careful to flag every unverified claim as an explicit
   assumption, this one slipped through unflagged. Worth either verifying against current
   Supabase Auth docs before Step 4, or adding it to the Assumptions list for consistency — not
   because it's likely wrong, but because the plan's own standard for itself says it should be
   checked.

4. **(Minor, no action needed — confirms the plan is right)** I checked whether
   `POST /repos/{owner}/{repo}/pages` with `build_type=workflow` truly needs no
   `source.branch` (which would mean A1's 422 worry is probably moot) versus whether `source`
   is required regardless of build_type. Public documentation is genuinely inconsistent on this
   point across GitHub's current and Enterprise Server docs, so the plan is right to treat it
   as an open assumption with a working fallback rather than asserting an answer either way. No
   change needed.

## Cut-this candidates

None found. The plan's scoping is unusually disciplined for a "stand up prod" task — it
explicitly defers config indirection, a promotion workflow, an admin UI, a custom domain,
service-worker re-enablement, and prod operations (backups/monitoring), all of which would be
legitimate scope creep here and are correctly left out. The `supabase/prod/add_member.sql`
template (vs. an ad-hoc one-off command, which is how dev currently adds members per
PROGRESS.md) is arguably slightly more process than dev has today, but it reduces
UUID-copy-paste risk for a repo that will be a different person's production system, so I'd
call that a reasonable, not excessive, step rather than a cut candidate.

## Verdict

Nothing found rises to "blocks the plan as written." The three "worth considering" items are
real but non-blocking: two are narrow technical correctness gaps in edge cases (one UX/cache
polish issue in D1, one maintainability caveat in D5's bootstrap script) that don't risk dev
and don't risk shipping prod wired to the wrong backend, and one is a minor rigor
inconsistency (an unverified claim that should probably be added to the plan's own Assumptions
list). The plan's core safety mechanism — never touching dev's working tree, dev's Supabase
project, or dev's OAuth client, verified through CLI flag behavior rather than assumed — holds
up under adversarial review. Ready to advance.

Findings count: 0 must-address, 3 worth-considering (2 critique, 1 alternative/consistency), 0
cut-this.
