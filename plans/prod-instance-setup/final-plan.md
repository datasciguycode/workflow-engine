# Separate production instance (new repo, new Supabase project, new Pages site): final plan

**Verdict: `approved-with-changes`.** See "Architect adjudication" at the end for what changed
relative to round 3 and why. The plan below is the one to execute; it stands on its own.

## Goal and hard constraint

Stand up an isolated production copy of the app:

- a new GitHub repo with its own Pages site,
- a new Supabase project with the schema replayed, minimal prod-only bootstrap data, Google
  OAuth, and the `agent-loop` Edge Function deployed,
- a verification pass before anyone calls it live.

**Hard constraint:** dev must not be disrupted while `threadsinc1@gmail.com` is testing today.
Every step runs against new resources from a **new working directory**. No step writes to:

- the dev repo `datasciguycode/workflow-engine` (no pushes, no settings changes),
- the dev working tree `/home/mmcbride/micah/claude/workflow-app`, apart from this plan
  directory, which is untracked,
- the dev Supabase project `utwyvtbzesswpoihmlic`,
- dev's **local** Supabase Docker stack (containers `supabase_*_workflow-app`, network
  `supabase_network_workflow-app`), which is running on this machine right now,
- dev's Google OAuth client.

There are a few places where a strictly read-only touch of dev would help. Each is marked
**[USER DECISION: optional read-only dev touch, U6]**, and each has a fallback that doesn't touch
dev at all.

## User decision points (stop and ask before proceeding)

Every place in this plan that needs the user's input is tagged **[USER DECISION: ...]**, so
`grep -n "USER DECISION"` finds all of them, and `grep -n "U<n>"` finds every point of use for a
given decision. Summary, in the order they're needed:

| # | Decision | Where | Needed before |
|---|----------|-------|---------------|
| U1 | Prod repo name (default `workflow-engine-prod`), and confirm it lives under the same GitHub account as dev (`datasciguycode`) | D2, A6 | Step 2. The name is baked into `<PROD_URL>` and the `/workflow-engine-prod/` base path, so it reaches Step 4 (Supabase URL Configuration), Step 5 (comments, PROGRESS.md), Step 6 (repo creation), Step 8 (first sign-in) and most of the Verification checklist |
| U2 | Free vs. Pro; same org as dev vs. a new org | D3 | Step 2 (`--org-id`) |
| U3 | Prod Anthropic key: new dedicated key (recommended) or reuse dev's | D7 | Step 7 |
| U4 | Account name and which workflow(s) go into prod | D5 | Step 5.4 |
| U5 | Checklist values: read from dev, user dictates, or start null | D5 | Step 5.4 |
| U6 | Optional read-only dev touches, four separate yes/no calls: dev checklist read (D5 Option A), schema-dump diff (A3), shared-origin coexistence test and cross-project token test (Verification, Recommended) | each tagged inline with "U6" | each point of use |
| U7 | Which people to add as prod members (don't add threadsinc1 automatically) | Step 8 | Step 8.3/8.4 |
| U8 | Acknowledge the service worker stays disabled | Risks | calling prod live |
| U9 | Keep-alive ping frequency (default every 3 days) and whether to add it now vs. upgrading to Pro instead | D9, Step 9 | before Step 9, or skip Step 9 if going Pro |

## Facts established while writing this (not assumptions)

- **Local main is ahead of GitHub.** Local `main` is 1 commit ahead of `origin/main`: `390fc11`,
  which only changes PROGRESS.md. All `web/**` commits are already pushed, so cloning from GitHub
  gets exactly what dev Pages is serving. We won't push dev to "fix" this; it's not our tree to
  touch today.
- **Dev repo and Pages config:** the dev repo is public, and its default branch is `main`
  (`git ls-remote --symref` reports `ref: refs/heads/main HEAD`). Its Pages config is
  `build_type: workflow` with no CNAME, so the site is served at
  `https://datasciguycode.github.io/workflow-engine/`.
- **Supabase CLI version:** v2.120.0 is installed, and v3.0.0 is available. **Don't upgrade during
  this task.** v2.120 is what dev's deploys were done with, and a major-version bump is unrelated
  risk.
- **`supabase db query` flags:** it supports `--project-ref <ref>` and `-f <file>`. This plan passes
  `--project-ref` explicitly on every remote command rather than relying on implicit link state.
- **Local Docker identity comes from `project_id`, not the directory.** `supabase/config.toml` sets
  `project_id = "workflow-app"`, and dev's live local containers and network are named from it
  (`supabase_db_workflow-app`, `supabase_studio_workflow-app`, `supabase_network_workflow-app`). A
  verbatim clone carries the same `project_id`, so local lifecycle commands (`supabase start`,
  `supabase stop`, `supabase db reset --local`) run from the prod clone would address **dev's**
  containers. Step 1 renames it in the clone before anything else.
- **`functions deploy` bundles with local Docker by default** on v2.120; `--use-api` ("Bundle
  functions server-side without using Docker") avoids that. This plan always passes `--use-api`.
- **`supabase db push` also pushes Vault secrets** from config.toml before migrations, unless
  `--skip-vault` is passed (per v2.120's `--help`). `[db.vault]` is commented out in config.toml
  today, so it's currently a no-op, but this plan passes `--skip-vault` anyway, for the same reason
  it avoids `supabase config push` (D4).
- **`supabase link` and `db push` take the remote DB password** via `-p`/`--password` or a prompt.
  This plan uses the `SUPABASE_DB_PASSWORD` environment variable read without echo (Step 3), so the
  password never lands in shell history.
- **Supabase projects:** dev's project is in org `swdeqnlbogugszsnyqlr` (region `us-west-2`, created
  2026-09-19). Every other project in the account is `INACTIVE` (paused), so only one free project
  is currently active. A second active free project fits under the 2-active-free-projects limit.
  - That limit is most likely counted **per user across every org they own or administer**, not
    per org (third-party write-ups disagree; not confirmed against Supabase's own billing docs).
    Either way a second free project fits today. The practical consequence: creating a **new free
    org** for prod (U2) does not buy an extra free slot. If the limit is hit, `projects create`
    simply errors; nothing is created or changed, so the failure is self-revealing and harmless.
- **Dev is a good stand-in for "new project defaults".** Dev was created after Supabase's Oct 2025
  switch to asymmetric JWT signing keys and publishable/secret API keys by default. It uses an
  `sb_publishable_...` key, and `agent-loop` with `verify_jwt` on (the default) works there. So a
  project created today should behave the same way.
- **Edge Function environment:** `agent-loop` reads `SUPABASE_URL`, `SUPABASE_ANON_KEY` (both
  injected by the platform) and `ANTHROPIC_API_KEY` (a secret we set ourselves). The function
  already sends CORS `*`.
- **`mcp-server` must not go to prod.** `supabase/functions/mcp-server` is also in the repo, with
  `verify_jwt = false` in config.toml. It's a dev testing aid with a shared-secret check. A bare
  `supabase functions deploy` (no function name) would deploy it to prod too, so always name
  `agent-loop` explicitly.
- **Stage checklists aren't in the repo.** `stages.checklist` (migration `20261104020000`) is only a
  column. The checklist values dev uses for "Joe's Auto Repair" were set by ad-hoc SQL and are not
  in seed.sql. The same goes for the threadsinc1 membership and any real jobs.
- **Migration grants are complete and explicit.** Migrations grant every table privilege the app
  needs to `authenticated` (`20261101000000`), the `item_events_seq_seq` sequence usage
  (`20261104000000`), and `execute` on every public RPC and private RLS helper (phase0/phase1, each
  after a `revoke all ... from public`). The app and `agent-loop` only ever act as `authenticated`
  (user JWT), never `anon` or `service_role`. So a fresh replay does not depend on the new project's
  default privileges or "auto-expose new tables" setting, and should not hit the "missing grants"
  failure from dev's first live run.
- **`scripts/*.py` only target local.** They all hard-target `http://127.0.0.1:54321` (local
  stack), so they can't accidentally hit prod or dev cloud. (Note they would hit **dev's** local
  stack, since that's what's listening on that port; don't run them from the prod clone.)
- **Stage constraints.** `stages` has `unique (workflow_id, title)` and a partial unique index
  allowing one `is_initial` stage per workflow (`stages_one_initial_per_workflow`). This matters for
  the upsert behavior in D5.
- **`AuthState` already depends on `SupabaseConfig`** (same namespace `WorkflowApp.Web.Services`;
  it builds the authorize URL and refresh requests from `SupabaseConfig.ApiUrl`). That's what lets
  D1 derive the storage key from the configured project rather than hardcode a second
  per-environment value.

## Key decisions

### D1. Shared-origin storage collisions: make the storage keys environment-specific in the prod copy (required, not cosmetic)

**The problem:**
- The prod Pages URL will be `https://datasciguycode.github.io/<prod-repo>/`. That is the **same
  origin** as dev, because an origin is scheme plus host, and the path doesn't count. So both apps
  share one `localStorage`, and within any one tab, one `sessionStorage`.
- `AuthState` stores its session under the fixed localStorage key `workflow-app.auth-session`.
- `index.html`'s build-id check guards itself with the fixed sessionStorage key `buildCheckDone`.

**What goes wrong with the auth key if we leave it:** signing into prod in a browser that's also
signed into dev overwrites dev's session with a prod token. Then dev sends that token to dev
Supabase, gets 401 or a failed refresh, `SignOutAsync` runs, and it removes the shared key. Each
site keeps logging the other out. It doesn't affect threadsinc1's device, but it would badly
confuse the owner's own testing, which is exactly the kind of "is dev broken?" scare to avoid.

**What goes wrong with `buildCheckDone` if we leave it:** sessionStorage is per origin *per tab*,
so **same-tab navigation** between dev and prod means the second site's one-time stale-build
forced reload (added 2026-11-06 for the iOS stale-cache complaints) silently never runs in that
tab. Low severity (cache freshness only), but it's the exact bug class that mechanism exists to
prevent.

**Fix (prod repo only). Derive the keys from things that already differ per environment, rather
than hardcoding a `-prod` suffix:**
- `web/Services/AuthState.cs`: replace the `const` with a key derived from the configured project:

  ```csharp
  // Scoped per Supabase project: dev and prod Pages share the datasciguycode.github.io origin,
  // so a fixed key would let each environment overwrite (and sign out) the other's session.
  private static readonly string StorageKey =
      "workflow-app.auth-session." + new Uri(SupabaseConfig.ApiUrl).Host.Split('.')[0];
  ```

  In prod this evaluates to `workflow-app.auth-session.<PROD_REF>`.
- `web/wwwroot/index.html`: key the build-check guard on the site's base URL (the script runs after
  the `<base>` tag, which CI rewrites per repo, so `document.baseURI` differs between dev and prod):

  ```js
  var k = 'buildCheckDone:' + document.baseURI;
  if (sessionStorage.getItem(k)) return;
  sessionStorage.setItem(k, '1');
  ```

  replacing the two `'buildCheckDone'` lines, plus a one-line note in the existing comment block.

Dev keeps its existing literal keys, so dev and prod no longer share either key, in either
direction, with no change to dev.

**Why derived rather than literal `-prod` keys:** the literal approach works, but it adds two more
permanent hand-maintained prod-vs-dev divergences next to `SupabaseConfig`. The derived forms are
environment-agnostic code: the *only* per-environment value left in the web app is
`SupabaseConfig`, which is exactly what the deferred config-indirection work will externalize.
These two edits can later be promoted to dev unchanged (dev users would be signed out once, when
dev's auth key changes; schedule that for a quiet moment), at which point they stop being
divergences at all.

**Rejected alternatives:**
- A custom domain for prod. A real fix, but needs a domain and DNS; out of scope today.
- Leaving it as is. It breaks side-by-side use.
- Storing the last-checked build id in a single flat key instead of a boolean. Dev's script would
  still read flat `buildCheckDone` and be suppressed by prod unless dev were also changed.

**iOS Home Screen web apps:** they *may* get separate storage containers, but we shouldn't rely on
that. Desktop Safari and Chrome definitely share storage.

### D2. Prod repo: a fresh clone from GitHub, push disabled toward dev, own local `project_id`

- Clone from `https://github.com/datasciguycode/workflow-engine.git` into a **sibling** directory:
  `/home/mmcbride/micah/claude/workflow-app-prod`.
  - **Not** inside the dev tree. The Supabase CLI searches upward for `supabase/`, and nested repos
    would be confusing.
  - Cloning from GitHub doesn't touch the dev working tree at all.
- Rename `origin` to `dev-upstream` and set its push URL to an invalid value, so a stray
  `git push` from the prod clone can never land on dev, while `git fetch dev-upstream` still works
  for promoting dev changes to prod.
- **Change `project_id` in the clone's `supabase/config.toml` to `workflow-app-prod`** immediately
  after cloning, and commit it. The CLI names local Docker containers and the network after
  `project_id`, not after the working directory, so without this a `supabase stop` from the prod
  clone would stop dev's live local stack. This is a permanent prod-vs-dev divergence; future
  `dev-upstream` merges must keep it (recorded in prod PROGRESS.md).
  - **Rejected:** relying on "just never run local commands from the prod clone". One habitual
    `supabase start` breaks that rule; the rename makes the mistake harmless.
- Keep the full history.
  - **Rejected:** squashing to a single "initial" commit. That loses `git log` context and makes
    future `dev-upstream` merges harder.
  - The history only contains dev's *publishable* key, which is designed to be public.
- **[USER DECISION: U1, repo name and owner account]** Default `workflow-engine-prod`. It must be
  **public**: Pages on private repos needs a paid GitHub plan, and dev is public anyway. The name
  becomes part of the URL, so changing it later means redoing the Supabase redirect URLs. If a
  different name is chosen, substitute it everywhere this plan says `workflow-engine-prod`
  (including the `/workflow-engine-prod/` base path and the Supabase URL Configuration).
  - **"Independently-owned" reading:** this plan reads the brief's "new, independently-owned GitHub
    repo" as *a repo independent of dev's repo* (own history going forward, own Pages site, own
    settings, no push path to dev), under the **same** GitHub account `datasciguycode`. Ask the
    user to confirm this as part of U1. If they want a different owner, replace `datasciguycode` in
    Step 6 and in `<PROD_URL>`; the Pages host then becomes `<other-owner>.github.io`, a
    **different origin**, so D1's collision disappears (keep the D1 edits anyway; they're
    harmless). A repo can also be transferred later, at the cost of the URL change described under
    "Repo name or owner change later" in Risks.

### D3. Supabase project: new free-tier project, same org and region as dev

- Create `workflow-engine-prod` in org `swdeqnlbogugszsnyqlr`, region `us-west-2`, using
  `supabase projects create`.
- **[USER DECISION: U2, plan tier and org]** Free-tier projects auto-pause after about 7 days
  without activity. Fine for a soft launch, not for real production. Pro is per-organization
  billing and would also start billing dev's project if both share an org.
  - If prod will be Pro, consider creating it in a **new org**, so dev stays free.
  - A new *free* org does not add free-project capacity (see Facts, "Supabase projects").
  - The commands work either way. Only `--org-id` changes.

### D4. Schema replay: `supabase db push --skip-vault` from the prod clone, no seed

- Run `supabase link --project-ref <PROD_REF>` **inside the prod clone**. Link state lives in
  `supabase/.temp/` (gitignored) per working directory, so dev's link to `utwyvtbzesswpoihmlic` is
  untouched.
- Then `supabase db push --dry-run --skip-vault`, followed by `supabase db push --skip-vault`.
- **Do not** use `--include-seed`. Dev's seed.sql is fixtures (isolation-test accounts, fixture
  user UUIDs absent from prod's `auth.users`, the "Feature Pipeline" SDLC test workflow, dummy
  items).
- **Do not** run `supabase config push`. It would push local config.toml values (site_url
  `127.0.0.1:3000`, etc.) onto prod's auth settings. Auth is configured in the dashboard (Step 4).
- **Rejected:** `pg_dump` of dev's schema restored into prod. That touches dev, carries over any
  untracked drift instead of surfacing it, leaves the migration history table out of line with the
  repo, and `db dump` runs in local Docker (the same `project_id` collision risk Step 1 solves).

### D5. Prod bootstrap data: a hand-written, prod-only SQL file, applied in two phases

- Leave `supabase/seed.sql` unchanged in the prod repo. It's only used by local `db reset`, and
  keeping it identical eases future dev-to-prod merges.
- Add `supabase/prod/bootstrap.sql`. It creates:
  1. one real account (a fresh UUID, hardcoded in the file; **not** the `1111...` fixture UUIDs),
  2. the real workflow(s) and their stages, including `checklist` values,
  3. **no** `account_members`, items, or chat.
- **Re-run semantics:**
  - `accounts`: `on conflict (id) do nothing`. Rename the account with a one-off `update` if needed.
  - `workflows` and `stages`: `on conflict (id) do update set <mutable columns> = excluded.<col>`,
    so editing a stage's title, order, flags or `checklist` in the file and re-running applies the
    edit. The file is the source of truth for prod's workflow definition.
  - **Not handled by re-runs:** removing a stage from the file does not delete it. Swapping two
    stages' titles in one run can trip `unique (workflow_id, title)`, and moving `is_initial` in
    one run can trip `stages_one_initial_per_workflow`. Do those as hand-written, ordered `update`s.
- Add `account_members` rows in a second step (`supabase/prod/add_member.sql`, a template filled in
  per run; see Step 5.5), after each person has signed into prod once. This is the same manual
  two-step pattern dev already uses, because `auth.users` rows only exist after first sign-in.

**[USER DECISION: U4, account name and workflows — answered 2026-11-07]** Account name:
**"Falcon Auto and Performance"**. Workflow: same shape as dev's "Joe's Auto Repair" (same
stages, order, `is_initial`/`is_terminal` flags, checklists), just renamed — the workflow/account
business name in prod is "Falcon Auto and Performance", not "Joe's Auto Repair". "Feature
Pipeline" and the isolation-test workflows stay dev-only, not copied.

**[USER DECISION: U5, where the checklist values come from]**
- **Option A, [USER DECISION: optional read-only dev touch, U6]:** one `select` against dev:
  `supabase db query --project-ref utwyvtbzesswpoihmlic "select title, sequence_order, is_initial, is_terminal, checklist from public.stages where workflow_id = '33333333-3333-3333-3333-333333333330' order by sequence_order nulls last"`
  - Run it from **any directory other than the dev tree**, with the explicit ref.
  - A single read with no locks of note; it can't affect the test session. Still "touching dev",
    so it's the user's call.
- **Option B (no dev touch):** the user dictates the checklist values.
- **Option C (no dev touch):** prod starts with `checklist` null; values are added to
  bootstrap.sql later and re-applied (the upsert makes that work). The agent treats checklists as
  soft hints anyway, per the migration comment.

**Rejected:** copying dev's real jobs/items into prod; putting the prod bootstrap into a migration
(migrations are shared schema, and prod data must never replay into dev); `do nothing` on every
table (edits would silently not take effect).

### D6. Google OAuth: a new OAuth client in the same Google Cloud project; don't edit dev's client

- In the GCP project that holds dev's OAuth client, create a **new** OAuth 2.0 Client ID (Web
  application), e.g. `workflow-engine-prod (Supabase)`, with one authorized redirect URI:
  `https://<PROD_REF>.supabase.co/auth/v1/callback`.
- **Rejected:** adding prod's callback to dev's client (edits a resource dev's live sign-in depends
  on today, and couples secret rotation). **Rejected:** a separate GCP project (second consent
  screen, verification and test-user list; overkill for now).
- **Nonce setting:** leave the Google provider's "Skip nonce check" **off** (the default). See A7.

**Caveat:** the consent screen is per GCP project, so it's shared with dev.
- If it's in **Testing** status, any prod user must be on its test-user list. Adding test users is
  additive and doesn't affect dev.
- **Don't** change publishing status or consent-screen branding today; that would affect dev.

### D7. Edge Function: deploy only `agent-loop`, server-side bundled, with its own Anthropic key

- `supabase functions deploy agent-loop --project-ref <PROD_REF> --use-api` from the prod clone.
  - `--use-api` bundles on Supabase's side instead of in local Docker. Use it on every prod
    deploy, including the A2 fallback redeploy.
  - Keep `verify_jwt` at its default (on). Dev proves it works with this project generation's keys.
- Set `ANTHROPIC_API_KEY` with `supabase secrets set --env-file supabase/.env --project-ref <PROD_REF>`.
  - The `.env` file keeps the value out of shell history. `supabase/.env` is gitignored by
    `supabase/.gitignore`; it won't exist in a fresh clone, so create it there.
- **[USER DECISION: U3, which Anthropic key — answered 2026-11-07]** Reuse dev's key for now,
  copied by **reading** dev's `supabase/.env` (a read of an untracked/gitignored file; doesn't
  affect the tree). A dedicated prod key can be split out later with a one-line secret change and
  no code change, whenever separate usage/billing visibility matters.

### D9. Keep-alive: one scheduled workflow, two purposes (avoids Pro tier for now)

**The problem:** a free-tier Supabase project auto-pauses after ~7 days with no activity (D3,
Risks). The obvious fix is a scheduled job that pings it. But a GitHub Actions `cron:`-triggered
workflow is itself auto-disabled after 60 days with **no repository activity** — and a scheduled
workflow *running* does not count as "activity" for that purpose; only real repo changes
(commits) do. So a ping-only workflow would eventually stop running, silently, and the project
would pause anyway with no warning.

**Fix:** one scheduled workflow that does both in a single run: pings Supabase, and makes a
trivial commit. The commit is real repo activity, so it resets GitHub's 60-day clock on the
workflow itself, which keeps the ping running indefinitely, which keeps Supabase alive
indefinitely.

- New file: `.github/workflows/keep-alive.yml` (prod repo only; dev doesn't need this).
- Runs on a `cron:` schedule, default every 3 days (comfortably inside the 7-day pause window).
- Each run: `curl` the prod Supabase REST URL (any cheap authenticated-free read, e.g.
  `GET /rest/v1/` with just the `apikey` header is enough to count as activity), then write the
  current UTC timestamp to a small tracked file (`supabase/prod/last-keepalive.txt`) and commit it
  if it changed.
- **[USER DECISION: U9]** Ping frequency (default 3 days), and whether to add this at all — if
  going straight to Pro tier (D3, U2), Step 9 can be skipped entirely, since Pro projects don't
  auto-pause.

**Rejected alternatives:**
- Pinging Supabase without the self-commit. Looks like it solves the problem but silently stops
  working after 60 days of workflow-only activity with no repo commits — worse than no fix,
  because it hides the eventual pause instead of preventing it.
- An external cron service (e.g. a third-party uptime pinger). Works, but adds an external
  dependency and a credential to manage outside this repo/Supabase for no real benefit over a
  workflow already native to the repo.
- Running the keep-alive from dev's repo against prod. Couples dev's workflow file to prod's
  existence; keeps it self-contained in the prod repo instead.

### D8. Pages: enable via `gh api` before the first push, then push the prod-edited commit

- Create the repo empty, enable Pages with `build_type=workflow`, then push.
- The **first** push must already contain the prod `SupabaseConfig` values; otherwise the first
  prod Pages deploy would ship an app wired to **dev's** backend. So the Supabase project must
  exist (Step 2) before the code edits (Step 5).
- The explicit `gh api` enable is necessary: `configure-pages@v6` defaults `enablement` to false,
  and the workflow's `GITHUB_TOKEN` lacks `administration:write` anyway.

## Assumptions (unverified)

- **A1. Pages on an empty repo.** `POST /repos/{owner}/{repo}/pages` with `build_type=workflow`
  succeeds on a repo with no commits yet. GitHub's docs are inconsistent on whether `source` is
  required. If it 422s, the fallback is in Step 6.
- **A2. New-project defaults match dev's.** A project created today has the same API-key and JWT
  defaults as dev: `SUPABASE_ANON_KEY` is still injected into Edge Functions, and the gateway's
  `verify_jwt` accepts the project's user JWTs. Supabase says legacy keys are being phased out "by
  end of 2026". If a Nov 2026 project lacks `SUPABASE_ANON_KEY`, `agent-loop` would send
  `apikey: undefined` and every REST call would 401. Caught by Step 2's api-keys check, Step 7's
  `secrets list` check, and the Verification "Direct call before the UI" curl. Fallback in Risks
  ("A2 fallback").
- **A3. No out-of-band drift.** Dev's schema contains nothing that isn't in `supabase/migrations/`.
  Likely (grant fixes were turned into migrations) but not proven. Prod verification exercises
  every RPC the UI and agent use, which is the practical drift test.
  - **[USER DECISION: optional read-only dev touch, U6]** A stronger check, best run after today's
    session: `supabase db dump --schema public,private --project-ref ...` against both projects,
    then diff. Run it from the prod clone (after Step 1's rename) or a scratch directory, never
    from the dev tree; `db dump` runs `pg_dump` in a local Docker container.
- **A4. (No longer an assumption; resolved.)** Earlier drafts assumed a dashboard "expose new
  tables" toggle would be left on. This plan creates the project via CLI, which has no such
  choice, and it doesn't matter: every grant the app needs is explicit in migrations (see Facts,
  "Migration grants are complete and explicit"). The Data API is on and exposes `public` by
  default for a CLI-created project; if Step 3's smoke checks or Step 8's sign-in show REST 404s
  for `public` tables, check Project Settings → Data API in the dashboard.
- **A5. OAuth client access.** The owner has access to the GCP project holding dev's OAuth client.
- **A6. Repo name and owner.** `workflow-engine-prod` under the same GitHub account as dev is
  acceptable. See D2, **[USER DECISION: U1]**.
- **A7. "Skip nonce check" off is correct for this app's sign-in flow.** Partially verified.
  - Checked: the setting governs whether Supabase Auth accepts a Google **ID token** whose nonce it
    can't match; community guides describe it as a workaround for native/ID-token sign-in and
    recommend leaving it off otherwise. The local config.toml comment points the same way.
  - Assumed: this app uses the hosted redirect flow (`AuthState` redirects to
    `/auth/v1/authorize?provider=google`; Supabase Auth does the code exchange with Google
    server-side), so the setting shouldn't come into play. Not confirmed against official docs.
  - Also assumed: a freshly created project returns tokens in the URL **fragment** (implicit flow)
    for a `/authorize` request without PKCE parameters, which is what `AuthState` parses and what
    dev does today.
  - How either would show up: Step 8.2's first sign-in fails, either with a nonce error on the
    Supabase callback (consider turning the setting on, and record why in prod PROGRESS.md) or
    with a return to `<PROD_URL>` carrying `?code=` and no session (compare against dev and stop;
    adapting `AuthState` to PKCE is a code change outside this plan).

## Implementation steps

Placeholders: `<PROD_REF>`, `<PROD_PUBLISHABLE_KEY>`, `<PROD_URL>` =
`https://datasciguycode.github.io/workflow-engine-prod/` (depends on U1).

**Before Step 2, get answers to U1 (repo name and owner) and U2 (tier and org).** U3-U5 can wait
until their steps.

**Every Supabase command below runs from `/home/mmcbride/micah/claude/workflow-app-prod`, never from
the dev directory.**

### Step 1. Clone the prod working copy and give it its own local identity (no dev-tree contact)

```bash
git clone https://github.com/datasciguycode/workflow-engine.git /home/mmcbride/micah/claude/workflow-app-prod
cd /home/mmcbride/micah/claude/workflow-app-prod
git branch --show-current   # must print: main  (Step 6 pushes main)
git remote rename origin dev-upstream
git remote set-url --push dev-upstream DISABLED-do-not-push-prod-to-dev
git remote -v   # confirm the push URL is the DISABLED one
test ! -e supabase/.temp && echo "not linked yet: OK"
```

**Then, before running any other `supabase` command in the clone,** rename the local project id:

```bash
sed -i 's/^project_id = "workflow-app"$/project_id = "workflow-app-prod"/' supabase/config.toml
grep -n '^project_id' supabase/config.toml   # must print: 5:project_id = "workflow-app-prod"
git commit -am "Give prod clone its own Supabase local project_id (avoid dev container collision)"
```

**Do not run `supabase start`, `supabase stop`, or `supabase db reset --local` from the prod clone
before this rename is committed.** They would act on dev's running local containers. This plan
never needs them at all; the rename just makes a slip harmless.

### Step 2. Create the prod Supabase project

**[USER DECISION: U1, U2]** must be answered first.

```bash
read -rs SUPABASE_DB_PASSWORD && export SUPABASE_DB_PASSWORD   # paste a generated password; store it in the password manager
supabase projects create workflow-engine-prod \
  --org-id swdeqnlbogugszsnyqlr --region us-west-2 --db-password "$SUPABASE_DB_PASSWORD"
supabase projects list            # note <PROD_REF>; wait for ACTIVE_HEALTHY
supabase projects api-keys --project-ref <PROD_REF> -o json   # note sb_publishable_... key
```

- Use a different `--org-id` if U2's answer is "new org".
- If `projects create` errors on the free-project limit, nothing was created; stop and revisit U2.
- Note whether a legacy `anon` key is listed. If none is, A2 is at risk; read the A2 fallback in
  Risks before Step 7.

### Step 3. Link the clone and replay migrations

In the same shell (so `SUPABASE_DB_PASSWORD` is still exported; otherwise re-run the `read` line):

```bash
supabase link --project-ref <PROD_REF>          # in the prod clone only
cat supabase/.temp/project-ref                   # must print <PROD_REF>, not utwyvtbzesswpoihmlic
supabase db push --dry-run --skip-vault          # expect all 12 migrations listed, nothing else
supabase db push --skip-vault
supabase migration list --linked                 # local and remote columns match, 12 rows
```

Smoke-check the schema:

```bash
supabase db query --project-ref <PROD_REF> "select table_name from information_schema.tables where table_schema='public' order by 1"
# expect: account_members, accounts, chat_messages, item_events, items, stages, workflows
supabase db query --project-ref <PROD_REF> "select grantee, privilege_type, table_name from information_schema.role_table_grants where grantee='authenticated' and table_schema='public' order by 3,2"
```

### Step 4. Configure Auth on the prod project (dashboard)

**Google Cloud console (D6):**
- Create the new OAuth client, with redirect URI `https://<PROD_REF>.supabase.co/auth/v1/callback`.
- If the consent screen is in Testing, add any prod users as test users.

**Supabase dashboard, prod project, Authentication:**
- **Sign In / Providers → Google:** enable it, paste the new client ID and secret, leave "Skip
  nonce check" off (A7).
- **Sign In / Providers → Email:** disable it. The app only uses Google; leaving email on lets
  anyone holding the publishable key create `auth.users` rows via `/auth/v1/signup` (harmless
  under RLS, but clutter).
  - Keep "Allow new users to sign up" **on**. Google first sign-in needs it.
- **URL Configuration:**
  - **Site URL:** `https://datasciguycode.github.io/workflow-engine-prod/`
  - **Redirect URLs:** `https://datasciguycode.github.io/workflow-engine-prod/**`
    (`AuthState.SignInWithGoogle` sends `redirect_to = NavigationManager.BaseUri`, which on Pages
    after the CI base-href rewrite is exactly `<PROD_URL>`.)
  - Do **not** add the dev URL. Do **not** add localhost unless you plan to run the prod repo
    locally against prod.

### Step 5. Make the prod-only code edits in the clone

1. **`web/Services/WorkflowApiClient.cs`, `SupabaseConfig`:** set `ApiUrl` to
   `"https://<PROD_REF>.supabase.co"` and `PublishableKey` to `<PROD_PUBLISHABLE_KEY>`. Update the
   comment above it to say "prod project workflow-engine-prod", and add: "This is the only
   per-environment value in the web app; see the config-indirection item in PROGRESS.md."
2. **Shared-origin storage keys (D1):**
   - `web/Services/AuthState.cs`: replace `private const string StorageKey = ...` with the derived
     `private static readonly string StorageKey` shown in D1, with its comment.
   - `web/wwwroot/index.html`: replace the `getItem`/`setItem('buildCheckDone', ...)` lines with
     the `document.baseURI`-keyed version shown in D1, and add a one-line note to the existing
     comment block saying why (shared github.io origin).
3. **Optional, recommended:** so prod and dev Home Screen icons and tabs can be told apart, set
   `name`/`short_name` in `web/wwwroot/manifest.webmanifest` and `<title>` in
   `web/wwwroot/index.html` to the same value, e.g. `Workflow Engine` (currently
   `WorkflowApp.Web`). Dev stays "WorkflowApp.Web". Icons are unchanged.
4. **`supabase/prod/bootstrap.sql`** (D5). **[USER DECISION: U4, U5]** must be answered first.
   Shape:

   ```sql
   -- Prod-only bootstrap. Run as postgres via:
   --   supabase db query --project-ref <PROD_REF> -f supabase/prod/bootstrap.sql
   -- Never part of migrations or seed.sql (must not replay into dev or local).
   -- Re-runnable: accounts are insert-once; workflows/stages are upserted, so edits here
   -- take effect on re-run. Removing a stage from this file does NOT delete it; swapping
   -- titles or moving is_initial needs hand-ordered updates (unique constraints).
   insert into public.accounts (id, name) values ('<new-uuid-A>', '<real business name>')
     on conflict (id) do nothing;
   insert into public.workflows (id, account_id, name, item_label) values
     ('<new-uuid-W>', '<new-uuid-A>', 'Joe''s Auto Repair', 'job')
     on conflict (id) do update set name = excluded.name, item_label = excluded.item_label;
   insert into public.stages (id, workflow_id, title, sequence_order, is_initial, is_terminal, checklist) values
     ('<new-uuid-S1>', '<new-uuid-W>', 'intake', 1, true, false, '["name","phone",...]'::jsonb),
     ... through payment_receipt_submitted (8, terminal) and closed (null, terminal)
     on conflict (id) do update set
       title = excluded.title, sequence_order = excluded.sequence_order,
       is_initial = excluded.is_initial, is_terminal = excluded.is_terminal,
       checklist = excluded.checklist;
   ```

   - Use literal, pre-generated UUIDs throughout (`uuidgen` once, paste in), so re-runs hit the
     same rows.
   - Don't include `account_id` in the workflow upsert's `set` list.
   - Check exact column names against migrations before running (e.g. whether `workflows` has
     other not-null columns without defaults).
5. **`supabase/prod/add_member.sql`:** a committed **template**, never edited in place:

   ```sql
   -- TEMPLATE. Don't run directly and don't edit in place. See PROGRESS.md "Adding a prod member".
   insert into public.account_members (account_id, user_id, role, display_name)
   select '<new-uuid-A>', id, '__ROLE__', '__DISPLAY_NAME__'
   from auth.users where email = '__EMAIL__'
   on conflict (account_id, user_id) do nothing
   returning account_id, user_id, role;
   ```

   - `<new-uuid-A>` is the real account UUID, filled in **once** when the file is created. Only
     `__ROLE__`, `__DISPLAY_NAME__` and `__EMAIL__` vary per run.
   - **Fill-and-run mechanism** (documented in prod PROGRESS.md, used in Step 8):

     ```bash
     sed -e "s/__EMAIL__/owner@example.com/" \
         -e "s/__ROLE__/owner/" \
         -e "s/__DISPLAY_NAME__/Owner Name/" \
         supabase/prod/add_member.sql > /tmp/add_member.run.sql
     grep -n "__" /tmp/add_member.run.sql   # must print nothing: every placeholder filled
     supabase db query --project-ref <PROD_REF> -f /tmp/add_member.run.sql
     rm /tmp/add_member.run.sql
     ```

     - The filled copy lives outside the repo, so nobody commits someone's email by accident.
     - `role` is `owner` or `member`. Display names containing `'` must be doubled (`O''Brien`);
       for names containing `/` or `&`, edit the scratch copy by hand instead of via sed.
   - The `returning` clause should print 1 row; 0 rows means the person hasn't signed in yet or is
     already a member.
6. **`PROGRESS.md` and `CLAUDE.md`:**
   - Replace PROGRESS.md with a prod snapshot: prod project ref, prod URL, the two deploy paths
     (functions deploy targets `<PROD_REF>` with `--use-api`), the "Adding a prod member"
     procedure, and a **"Divergences from dev (keep on every merge)"** list:
     - `project_id = "workflow-app-prod"` in `supabase/config.toml` (permanent),
     - `SupabaseConfig` values (permanent until config indirection lands),
     - the two D1 storage-key edits (upstreamable to dev later; once dev has them they stop being
       divergences),
     - `supabase/prod/` (prod-only files; dev never has them),
     - the A2 fallback, if applied,
     - PROGRESS.md and the CLAUDE.md prod header themselves.
   - Also record a **"Merging from dev-upstream"** note: PROGRESS.md always conflicts (both repos
     rewrite it), so resolve it with `git checkout --ours PROGRESS.md`, then re-check the
     divergences list above against `git diff dev-upstream/main` before pushing.
   - Add a short note at the top of CLAUDE.md: "This is the PROD repo; dev is
     datasciguycode/workflow-engine. Always pass `--project-ref <PROD_REF>` to Supabase commands.
     Don't run local-stack commands (`supabase start`/`stop`/`db reset --local`, `scripts/*.py`)
     here. Deploy functions with `--use-api`, and only `agent-loop`."
7. **Verify the edits:**
   - `grep -rn utwyvtbzesswpoihmlic web/` prints nothing.
   - `grep -n buildCheckDone web/wwwroot/index.html` shows only the `document.baseURI`-keyed form
     (no bare `'buildCheckDone'` literal passed to `getItem`/`setItem`).
   - `grep -n StorageKey web/Services/AuthState.cs` shows the derived `static readonly` definition.
   - `grep -n '^project_id' supabase/config.toml` still shows `workflow-app-prod`.
   - `dotnet build web/WorkflowApp.Web.csproj` succeeds.
   - Commit, but don't push yet.

### Step 6. Create the GitHub repo, enable Pages, push

**[USER DECISION: U1]** (name and same-account owner) must be confirmed first.

```bash
gh repo create datasciguycode/workflow-engine-prod --public \
  --description "Workflow Engine (production)"     # no --source/--push yet
gh api -X POST repos/datasciguycode/workflow-engine-prod/pages -f build_type=workflow
git remote add origin https://github.com/datasciguycode/workflow-engine-prod.git
git push -u origin main
gh run watch --repo datasciguycode/workflow-engine-prod
gh api repos/datasciguycode/workflow-engine-prod/pages --jq '.html_url,.build_type'
```

- The push triggers `deploy-pages.yml` (the path filter matches `web/**` on a first push).
- `configure-pages` derives `base_path=/workflow-engine-prod` from the repo, so the base-href
  rewrite and 404.html (`pathSegmentsToKeep = 1`) work unchanged.
- **If the Pages POST 422s on the empty repo (A1):** push first (the first run fails at
  `configure-pages` and deploys nothing), then run the `gh api` POST, then
  `gh workflow run deploy-pages.yml --repo datasciguycode/workflow-engine-prod`.
- **Don't** copy dev's repo settings or secrets. The workflow needs none: it uses only
  `GITHUB_TOKEN` and OIDC.
- **Expected half-built window (benign):** from this push until Step 8 finishes, `<PROD_URL>` is
  live and Google sign-in already works (Step 4), but the app shows no workflows (no bootstrap
  data, no membership, so RLS returns empty), and chat fails (before Step 7 the function doesn't
  exist; between Steps 7 and 8 there's nothing for it to act on). That's by design of the step
  order, not a fault. Don't share the URL or debug "empty app" symptoms until Step 8 is done.

### Step 7. Deploy `agent-loop` and set its secret

**[USER DECISION: U3, which Anthropic key]** must be answered first.

```bash
printf 'ANTHROPIC_API_KEY=%s\n' '<prod key>' > supabase/.env   # gitignored
git status --short supabase/                                     # .env must NOT appear
supabase secrets set --env-file supabase/.env --project-ref <PROD_REF>
supabase functions deploy agent-loop --project-ref <PROD_REF> --use-api   # name it explicitly; never bare deploy
supabase functions list --project-ref <PROD_REF>                 # exactly one function: agent-loop
supabase secrets list --project-ref <PROD_REF>                   # ANTHROPIC_API_KEY present (+ platform SUPABASE_*)
```

(To keep the key out of shell history, write `supabase/.env` with an editor instead of `printf`
if preferred.)

Check two things:
- In `secrets list`, `SUPABASE_ANON_KEY` should appear among the platform-provided names. If it's
  absent, apply the A2 fallback (Risks) **including its redeploy** before Step 8.
- If `functions list` shows `mcp-server`, delete it immediately:
  `supabase functions delete mcp-server --project-ref <PROD_REF>`.

### Step 8. Bootstrap data and first owner

1. `supabase db query --project-ref <PROD_REF> -f supabase/prod/bootstrap.sql`
2. The owner opens `<PROD_URL>` and signs in with Google. The app should show **no workflows**
   (no membership yet, so RLS returns nothing). If sign-in fails with a nonce error, or returns
   with `?code=` and no session, see A7.
3. Fill and run `add_member.sql` for the owner (Step 5.5's block) with `__ROLE__` = `owner`.
   Expect 1 row returned. Reload; the workflow should appear.
4. **[USER DECISION: U7, who gets prod access]** Additional prod users follow the same two steps:
   they sign in, then you fill and run the template with `__ROLE__` = `member` (or `owner`).
   **Don't** automatically add threadsinc1 to prod.
5. Push the final state of the prod repo (PROGRESS.md updates, any A2 fallback commit) to
   `origin`.

### Step 9. (Optional, [USER DECISION: U9]) Add the keep-alive workflow

Skip this step entirely if U2's answer is Pro tier — Pro projects don't auto-pause.

Create `.github/workflows/keep-alive.yml` in the prod repo:

```yaml
name: Keep Supabase project alive
on:
  schedule:
    - cron: '0 6 */3 * *'   # every 3 days; adjust per U9
  workflow_dispatch: {}

permissions:
  contents: write   # needed to commit the timestamp file

jobs:
  ping:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Ping Supabase (counts as project activity)
        run: |
          curl -sS -o /dev/null -w "%{http_code}\n" \
            "https://<PROD_REF>.supabase.co/rest/v1/" \
            -H "apikey: <PROD_PUBLISHABLE_KEY>"
      - name: Record the ping (real repo activity, resets GitHub's 60-day cron-disable clock)
        run: |
          mkdir -p supabase/prod
          date -u +"%Y-%m-%dT%H:%M:%SZ" > supabase/prod/last-keepalive.txt
          git config user.name "keep-alive-bot"
          git config user.email "actions@github.com"
          git add supabase/prod/last-keepalive.txt
          git diff --cached --quiet || git commit -m "Keep-alive ping $(date -u +%Y-%m-%d)"
          git push
```

- Substitute `<PROD_REF>` and `<PROD_PUBLISHABLE_KEY>` as elsewhere in this plan.
- `workflow_dispatch` lets you trigger it manually to test it once right after adding it, rather
  than waiting up to 3 days for the first scheduled run.
- Verify after adding: `gh workflow run keep-alive.yml --repo datasciguycode/workflow-engine-prod`,
  then `gh run watch`, then confirm `supabase/prod/last-keepalive.txt` was committed.
- This workflow needs no new secrets: the publishable key is public by design (same key already
  shipped in the client bundle), and the commit uses the default `GITHUB_TOKEN`.

## Verification checklist

Every item under **Required** must pass before calling prod live. Items under **Recommended** are
each the user's call (they touch dev read-only, or need a dev session); skipping one doesn't block
go-live, but the listed consequence applies.

### Required

**Sign-in and session:**
- [ ] **Sign-in round trip.** On desktop and iPhone Safari: Google, then back to `<PROD_URL>`, with
  the fragment stripped and the email shown. A redirect to the Site URL with an error, or to the
  dev URL, means the allowlist is wrong.
- [ ] **Session persistence.** A hard reload while signed in stays signed in.
- [ ] **Token refresh works.** Either leave a tab open for more than an hour and then act, or
  force it: in devtools, edit `expires_at` in the localStorage entry
  `workflow-app.auth-session.<PROD_REF>` to a past value, reload, and act. Expect no sign-out, and
  a POST to `/auth/v1/token?grant_type=refresh_token` on **prod's** ref.

**Routing and build:**
- [ ] **Deep-link refresh.** Open a workflow, then a job (URL
  `/workflow-engine-prod/workflow/<id>/...`). Hard refresh lands on the same screen, not a 404 or
  white screen. Same from a pasted URL in a fresh tab.
- [ ] **Build id stamped.** View source of `<PROD_URL>`: `<meta name="build-id">` is not `dev`,
  `<base href="/workflow-engine-prod/" />`, and the build-check script uses the
  `document.baseURI`-keyed guard. In devtools, sessionStorage shows
  `buildCheckDone:https://datasciguycode.github.io/workflow-engine-prod/`.
- [ ] **No dev host in the shipped bundle.** In the network tab, every `rest/v1`, `auth/v1` and
  `functions/v1` request goes to `<PROD_REF>.supabase.co`, never to `utwyvtbzesswpoihmlic`.

**Agent chat (agent-loop):**
- [ ] **Direct call before the UI.** `curl -i -X OPTIONS https://<PROD_REF>.supabase.co/functions/v1/agent-loop`
  returns CORS headers. A POST with a real prod user JWT (copied from localStorage) and a minimal
  body returns 200 with a reply, not 401 or 500.
  - **401 from the gateway** means a `verify_jwt` or key-generation problem (A2).
  - **500 with an Anthropic auth error** means a bad key (same failure as dev's first live run).
- [ ] **In the UI.** On the New Job screen, send a create-job message. The agent replies, the job
  appears in the list, and its history shows an event. That proves `create_item`, the
  `item_events` insert and sequence grant, and that `chat_messages` persist.
- [ ] **Complete Stage.** "Complete Stage" and a field-update message both work (`move_stage`,
  `update_data`).
- [ ] **Anthropic usage.** The Anthropic console shows usage on the **prod** key.

**Isolation:**
- [ ] **Within prod (RLS).** A second Google account that has signed in but has **no**
  `account_members` row sees zero workflows and jobs, and its agent chat can't act on the owner's
  workflow. Also directly:
  `curl "https://<PROD_REF>.supabase.co/rest/v1/workflows" -H "apikey: <PROD_PUBLISHABLE_KEY>" -H "Authorization: Bearer <non-member JWT>"`
  returns `[]`.
- [ ] **Anonymous.** The same request with only the publishable key (no user JWT) returns `[]` or
  401, not rows.
- [ ] **Prod data never in dev.** By construction: no command in this plan targets dev's ref.
- [ ] **Membership doesn't carry over.** Dev memberships don't exist in prod. If threadsinc1 (or
  the owner's dev identity) signs into prod before being added, they see nothing.

**Dev unaffected (final check):**
- [ ] **Dev still works.** As a normal user, dev Pages still loads and signs in.
- [ ] **No git or link changes in dev.** `git -C /home/mmcbride/micah/claude/workflow-app status`
  shows only the untracked `plans/prod-instance-setup/` directory, and
  `cat /home/mmcbride/micah/claude/workflow-app/supabase/.temp/project-ref` still prints
  `utwyvtbzesswpoihmlic`.
- [ ] **Dev's local stack untouched.** `docker ps --format '{{.Names}}' | grep workflow-app`
  still lists dev's `supabase_*_workflow-app` containers running, and nothing named
  `*_workflow-app-prod` exists.

### Recommended (each is a separate **[USER DECISION: optional read-only dev touch, U6]**)

- [ ] **Shared-origin coexistence (D1), U6.** In one desktop browser, sign into dev and into prod
  in two tabs. Reload both: each stays signed in as its own environment (localStorage shows both
  `workflow-app.auth-session` and `workflow-app.auth-session.<PROD_REF>`). Then, in one tab, go
  dev → prod URL and check that the prod `buildCheckDone:...workflow-engine-prod/` entry gets set
  despite dev's `buildCheckDone` being present.
  - If skipped: side-by-side dev/prod use in one browser is unverified.
- [ ] **Cross-project, prod token against dev, U6.** Send a prod user JWT to **dev** REST:
  `curl "https://utwyvtbzesswpoihmlic.supabase.co/rest/v1/workflows" -H "apikey: <dev publishable key>" -H "Authorization: Bearer <prod JWT>"`
  expecting 401. A single rejected read with zero effect on dev.
  - **Converse:** a dev JWT against prod REST returns 401. Sends nothing to dev; only needs a dev
    token copied from a browser that's already signed in.
  - If skipped: cross-project token rejection rests on Supabase's per-project signing keys (a
    platform guarantee, not observed).

## Risks and edge cases

**Shipping a prod build wired to dev.** If the Step 5 edits are skipped or partly missed, the prod
site reads and writes **dev** data, including the test user's real jobs. The single worst failure.
Mitigations: the `grep` check in Step 5.7, ordering the first push after the edits (D8), and the
network-tab check in verification.

**`supabase` commands hitting the wrong project.** Every remote command passes
`--project-ref <PROD_REF>` or runs only after the `cat supabase/.temp/project-ref` check in the
prod clone. Never run Supabase commands from the dev directory during this task; the CLI's upward
directory search means a `cd` slip would silently use dev's link.

**Local Docker commands hitting dev's running stack.** Local lifecycle commands address containers
by `project_id`, not directory. Until Step 1's rename is committed, running any of them from the
prod clone would act on **dev's** live containers; this plan doesn't need them at all.
`functions deploy` always gets `--use-api`. `scripts/*.py` hard-target dev's local stack; don't run
them from the prod clone.

**Half-built window after Step 6.** Expected and benign (see Step 6). Don't share `<PROD_URL>`
until Step 8 is complete and Required verification passes.

**A2 fallback: no `SUPABASE_ANON_KEY` in the function environment.**
1. In the prod repo only, change line 25 of `supabase/functions/agent-loop/index.ts` to read the
   new-format key by **property access**:
   `Deno.env.get("SUPABASE_ANON_KEY") ?? JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}")["default"]`.
   `SUPABASE_PUBLISHABLE_KEYS` is documented as a JSON object keyed by key name (e.g.
   `{"default": "sb_publishable_..."}`). Confirm the key name against `secrets list` or the docs;
   if the project's publishable key has a different name, use that.
   - Alternatively, set a custom secret `PUBLISHABLE_KEY` (add to `supabase/.env`, re-run
     `supabase secrets set --env-file supabase/.env --project-ref <PROD_REF>`) and read that.
   - Because the `??` form still prefers `SUPABASE_ANON_KEY`, this edit is backward-compatible
     and is a good candidate to upstream to dev later, removing the divergence.
2. **Redeploy:** `supabase functions deploy agent-loop --project-ref <PROD_REF> --use-api`.
   Editing the file alone changes nothing.
3. Re-run the Verification "Direct call before the UI" curl; expect 200.
4. Commit in the prod repo and record the divergence in prod PROGRESS.md.

**A2 variant: gateway rejects ES256 user JWTs with `verify_jwt` on.** Unconfirmed third-party
reports; dev's identical setup works. Fallback: deploy with `--no-verify-jwt` **only** together
with an in-function `getClaims` or JWT check. (Even without one, the function forwards the JWT to
PostgREST, which enforces RLS, but don't ship a no-verify function without stating that reasoning.)

**Free-tier auto-pause (D3).** A paused prod project means the app silently fails to load data.
Decide on Pro, or Step 9's keep-alive workflow, before real users depend on it (U2, U9).

**Keep-alive workflow stops working (D9).** If `contents: write` permission is ever removed from
the workflow, or branch protection on `main` requires PRs/reviews, the commit step fails silently
(the push errors but the job still "succeeds" at the ping). Check
`gh run list --workflow=keep-alive.yml` occasionally, or add a failure notification if this matters
enough. If `supabase/prod/last-keepalive.txt`'s timestamp is more than ~6 days old, something's
wrong — investigate before the project pauses.

**Google consent screen shared with dev.** Editing branding, scopes, or publishing status affects
dev's sign-in. This plan only adds a client and, possibly, test users.

**bootstrap.sql re-runs (D5).** Re-running applies workflow/stage edits but never deletes stages;
title swaps or `is_initial` moves can hit unique constraints. The file header says so.

**add_member template leakage.** If someone edits `supabase/prod/add_member.sql` in place, `git
status` shows it modified; revert with `git checkout -- supabase/prod/add_member.sql` rather than
committing an email address.

**Merge drift from dev-upstream.** Every dev-to-prod merge is a chance to silently overwrite a
divergence (most dangerously `SupabaseConfig`, which would re-point prod at dev). The PROGRESS.md
"Divergences" list and the Step 5.7 `grep` checks are the guard; re-run those greps after every
merge, before pushing.

**Service worker. [USER DECISION: U8]** index.html's comment says to "re-enable before the real
production deploy". This plan deliberately **does not**: the iOS stale-cache problems the build-id
reload fixes would come back, and offline support isn't a stated prod requirement. Flagged for the
user to acknowledge rather than silently skipped.

**Repo name or owner change later.** Changes the URL: update the Supabase Site URL and Redirect
URLs, and Home Screen icons need re-adding. Settle U1 before Step 2.

**Rollback.** Everything is new and separate: `gh repo delete datasciguycode/workflow-engine-prod`;
delete or pause the Supabase project from the dashboard; delete the new OAuth client;
`rm -rf /home/mmcbride/micah/claude/workflow-app-prod`. None of it affects dev.

## Out of scope (deliberate)

- **Config indirection.** Moving the Supabase URL/key out of hardcoded C# is deferred per the task.
  After this plan, `SupabaseConfig` is the *only* per-environment value in the web app (D1's keys
  derive from it or from the base URL), so that work has a single seam to replace. A natural shape
  is build-time substitution in `deploy-pages.yml` (it already rewrites `<base href>` and the build
  id with `sed`) from repo variables, which would let dev and prod share identical source.
- **Promotion workflow.** `git fetch dev-upstream` then merge, re-running `db push --skip-vault`
  and `functions deploy agent-loop --use-api` against prod, is enabled by D2 but not designed here.
- **Admin UI** for accounts and members. Deferred until after prod is live and a couple of real
  customers have been onboarded by hand (2026-11-07 decision) — at that point it'll be clearer
  which parts of account/member creation are actually worth building a page for, versus guessing
  now. Would need: new RLS-safe RPCs for creating an account + initial workflow (today this is a
  database-side-only operation, not reachable from the app at all), pages for an owner to see
  pending sign-ins and add/remove members by email, and a decision on who's allowed to create a
  new *account* in the first place.
- **Custom domain** for prod (also the cleaner long-term fix for D1).
- **Running a prod local stack.** Not needed; after the `project_id` rename it would be possible
  but would compete with dev's local stack for ports 54321-54324.
- **Re-enabling the service worker** or offline PWA support.
- **Dev bookkeeping and upstreaming.** After today's test session, in the dev tree, as a separate
  small change: note in dev's PROGRESS.md/CLAUDE.md that prod exists; commit/push dev's unpushed
  `390fc11`; optionally upstream the D1 derived storage keys (one-time dev sign-out) and the A2
  fallback, if applied.
- **Prod operations.** Backups and PITR, monitoring, alerting.
- **Making the prod repo private.** Raised 2026-11-07, deferred but intended to happen
  eventually. GitHub Pages only serves from a private repo on a paid plan (Pro/Team/Enterprise,
  $4/mo minimum) — the free plan requires the repo be public, same as dev today. The publishable
  key being visible isn't itself a security concern (RLS is the real boundary, and the key is
  designed to be safe to expose), so what a private repo actually buys is hiding the app's source
  code and commit history, not any secret. Revisit alongside the Supabase Pro decision (D3/U2)
  once prod is carrying real customers.
- **Migrating real dev data** (jobs, chat history) into prod.
- **Job assignment / claiming within one account.** Raised 2026-11-07, refined same day. Not an
  access-control feature — everyone on an account keeps full visibility into every job (no RLS
  change), which matters because two coworkers often need to hand the *same* job to each other
  mid-process (today's stage model already supports that hand-off naturally: completing a stage
  moves the job forward for whoever picks it up next). What's missing is lighter-weight: an
  `assigned_to` field on `items` (nullable — unassigned = open for anyone), a "claim this job"
  action, a "hand off to [coworker]" action, and optionally a "my jobs" vs. "all jobs" UI filter.
  Fits the existing agent-loop tool pattern well — an `assign_item` tool alongside
  `create_item`/`move_stage`/`update_data`/`add_note` would be a natural, small addition. No RLS
  or schema-security change needed, just a new nullable column + UI/tool surface. Smaller in
  scope than the earlier per-user-isolation framing (discarded) — revisit once Falcon or another
  account actually has multiple workers sharing a job queue.
- **Upcoming-appointments list on the intake screen.** Raised 2026-11-07. Show the next 10
  appointments (items with a `scheduled_at` set), sorted ascending by date/time, with customer
  name, below the chat textbox on the New Job screen. Pure UI change — no new agent tool or
  schema change needed, since `GetItemsAsync` already fetches all of a workflow's items; this is
  just filtering/sorting/rendering what's already fetched. Smaller in scope than the scheduling
  visibility tool above (that one's for the agent to use in chat; this is a static on-screen
  list), and could land independently of it.
- **Scheduling visibility (conflict awareness + "what's booked on day X").** Raised 2026-11-07,
  broadened same day. `agent-loop` currently has no way to see other jobs' `scheduled_at` values
  at all (`update_data` only writes to the job it's called on; confirmed no tool or logic
  anywhere in `supabase/functions/agent-loop/index.ts` queries sibling items) — so it can
  neither warn about a new booking overlapping an existing one, nor answer a direct question
  like "any appointments on the 20th?" during intake. One new read-only tool covers both:
  `list_scheduled_items` (or similar), querying other items' `scheduled_at` within the same
  workflow, callable either when the agent is about to set a new `scheduled_at` (to flag, not
  block, an overlap — double-booking is sometimes intentional) or when the user asks a
  scheduling question directly. Small scope: one new tool, no schema change.
- **Anthropic spend alert.** Raised 2026-11-07. The shared Anthropic API key (dev and prod both
  use it, per U3) has no expiration date, but its prepaid balance can run out with no warning,
  which looks identical to an expired key (agent-loop calls start failing). Follow-up: set a
  spend/usage alert in the Anthropic Console (Settings → Billing) so a threshold notification
  arrives before the balance hits zero, and check the Usage page's current balance/burn rate.
  Not done as part of this plan — purely a Console settings change, not a code or infra task.
- **Photo-to-field extraction (e.g. VIN from a photo of the dash/plate).** Raised 2026-11-07.
  Feasible without new architecture — `agent-loop` already passes messages straight through to
  Anthropic, which supports image content blocks in the same format, so the agent could read text
  out of a photo and call its existing `update_data` tool with it. Would need: an image
  attach/capture control in the chat UI, sending image content blocks (not just text) from
  `WorkflowApiClient.cs`, and a prompt addition telling the agent to offer extracted values back
  to the user. A small-to-medium UI+prompt feature, not a backend/infra change — deferred to its
  own pass after prod is up.

---

## Architect adjudication

### Verdict: `approved-with-changes`

The round-3 plan was sound and safe; both lenses independently cleared it. The changes below are
editorial fixes plus one architectural adjustment. None alter the step order, the dev-isolation
guarantees, or any decision point, so no further review round is needed.

### Findings adjudicated

| Source | Finding | Ruling |
|---|---|---|
| Plan-reviewer | A4 describes a dashboard toggle the CLI path never encounters (orphaned text) | **Valid, fixed.** A4 is rewritten as resolved/not-an-assumption. I checked the migrations: every grant the app needs (tables, sequence, public RPCs, private RLS helpers) is explicit and targeted at `authenticated`, and neither the app nor `agent-loop` uses `anon`/`service_role` grants, so the project's default-privilege setting is irrelevant. That fact was strengthened in "Facts established", and A4 keeps a one-line pointer for the unlikely "Data API off" symptom. |
| Sanity-check 1 | Free-tier "2 active projects" may be per-account across orgs | **Valid, acknowledged.** A web search leans toward "per user across orgs they own/admin", but sources conflict and it's unconfirmed against Supabase's own docs. Added to Facts and D3. The only planning consequence: a new *free* org (U2) doesn't add capacity. The failure is self-revealing and non-destructive (noted in Step 2). |
| Sanity-check 2 | Step 6 to Step 8 window (sign-in works, app empty, chat fails) isn't called out as expected | **Valid, fixed.** Added an "Expected half-built window" note to Step 6 and a Risks entry. |
| Sanity-check 3 | Rejecting pg_dump restore was correct | **Agreed, no action** beyond adding the Docker/`project_id` reason to D4's rejection. |

### Architectural-fit review (my own findings)

1. **Divergence surface vs. the deferred config-indirection work (changed).** Round 3 hardcoded
   `-prod` storage keys in two more files, which would have left three hand-maintained
   per-environment values for every dev-to-prod merge to protect and for config indirection to
   untangle. D1 now derives the auth key from `SupabaseConfig.ApiUrl` (AuthState already depends
   on `SupabaseConfig`) and keys the build check on `document.baseURI` (which CI already rewrites
   per repo). The web app is left with exactly one per-environment seam, `SupabaseConfig`, and the
   D1 edits become upstreamable rather than permanent. Verification items and Step 5.7 greps were
   updated to match. Cost: slightly more code than a one-line literal; both forms are trivially
   checked in devtools.
2. **Merge mechanics for a long-lived fork (added).** The plan sets up `dev-upstream` for future
   promotion but didn't say how merges keep prod's divergences intact. PROGRESS.md is rewritten
   in both repos and will conflict on every merge, and a careless merge of `WorkflowApiClient.cs`
   would silently re-point prod at dev, which is the plan's own "single worst failure". Added a
   "Divergences from dev" list and a "Merging from dev-upstream" note to prod PROGRESS.md (Step
   5.6), plus a "Merge drift" risk telling the executor to re-run the Step 5.7 greps after every
   merge.
3. **DB password handling (added).** `link`/`db push` need the remote DB password; round 3 put it
   inline on the command line. It's now read once into `SUPABASE_DB_PASSWORD` without echo.
4. **Final push (added).** Step 8.5 pushes the prod repo's final state, so PROGRESS.md and any A2
   fallback commit aren't left local-only. That matches the project's CLAUDE.md milestone
   convention.
5. **Fit otherwise good.** The plan respects the app's two existing deploy paths (Pages via
   path-filtered push, functions via manual CLI), reuses `deploy-pages.yml` and 404.html
   unchanged (the base path comes from `configure-pages`), keeps migrations as the single shared
   schema source, and keeps prod-only data out of migrations and seed. That is consistent with
   how the codebase separates schema, fixtures and environment data. The `project_id` rename and
   `--use-api` correctly handle the one place where the Supabase CLI's local identity is not
   directory-scoped.

### Things to flag to the user before starting

- Answer **U1 and U2 before Step 2**. The repo name is baked into the URL and the Supabase auth
  allowlist, and the tier/org choice can't be cheaply changed afterwards.
- From Step 6 until Step 8, the prod URL is live but empty and chat fails. That's expected; don't
  share the URL until Required verification passes.
