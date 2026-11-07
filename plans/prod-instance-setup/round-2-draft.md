# Separate production instance (new repo, new Supabase project, new Pages site): round 2 draft

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
- dev's Google OAuth client.

There are a few places where a strictly read-only touch of dev would help. Each is marked
**[USER DECISION: optional read-only dev touch]**, and each has a fallback that doesn't touch dev
at all.

## User decision points (stop and ask before proceeding)

Every place in this plan that needs the user's input is tagged **[USER DECISION: ...]**, so
`grep -n "USER DECISION"` finds all of them. Summary, in the order they're needed:

| # | Decision | Where | Needed before |
|---|----------|-------|---------------|
| U1 | Prod repo name (default `workflow-engine-prod`) | D2, A6 | Step 2 (it becomes the URL used in Steps 4-6) |
| U2 | Free vs. Pro; same org as dev vs. a new org | D3 | Step 2 (`--org-id`) |
| U3 | Prod Anthropic key: new dedicated key (recommended) or reuse dev's | D7 | Step 7 |
| U4 | Account name and which workflow(s) go into prod | D5 | Step 5.4 |
| U5 | Checklist values: read from dev, user dictates, or start null | D5 | Step 5.4 |
| U6 | Optional read-only dev touches: dev checklist read (D5), schema-dump diff (A3), cross-project token test and shared-origin coexistence test (Verification, recommended section) | various | each point of use |
| U7 | Which people to add as prod members (don't add threadsinc1 automatically) | Step 8 | Step 8.3/8.4 |
| U8 | Acknowledge the service worker stays disabled | Risks | calling prod live |

## Facts established while writing this (not assumptions)

- **Local main is ahead of GitHub.** Local `main` is 1 commit ahead of `origin/main`: `390fc11`,
  which only changes PROGRESS.md. All `web/**` commits are already pushed, so cloning from GitHub
  gets exactly what dev Pages is serving. We won't push dev to "fix" this; it's not our tree to
  touch today.
- **Dev repo and Pages config:** the dev repo is public. Its Pages config is `build_type: workflow`
  with no CNAME, so the site is served at `https://datasciguycode.github.io/workflow-engine/`.
- **Supabase CLI version:** v2.120.0 is installed, and v3.0.0 is available. **Don't upgrade during
  this task.** v2.120 is what dev's deploys were done with, and a major-version bump is unrelated
  risk.
- **`supabase db query` flags:** it supports `--project-ref <ref>` and `-f <file>`. This plan passes
  `--project-ref` explicitly on every remote command rather than relying on implicit link state.
- **Supabase projects:** dev's project is in org `swdeqnlbogugszsnyqlr` (region `us-west-2`, created
  2026-09-19). Every other project in the account is `INACTIVE` (paused), so only one free project
  is currently active. A second active free project fits under the 2-active-free-projects limit.
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
- **Migration grants are complete.** Migrations already include the table grants and the
  `item_events_seq_seq` sequence grant that dev was missing on its first cloud run (2026-11-01 and
  2026-11-04 fixes). A fresh replay should not hit the "missing grants" failure from the first live
  run.
- **`scripts/*.py` only target local.** They all hard-target `http://127.0.0.1:54321` (local
  stack), so they can't accidentally hit prod or dev cloud.
- **Stage constraints.** `stages` has `unique (workflow_id, title)` and a partial unique index
  allowing one `is_initial` stage per workflow (`stages_one_initial_per_workflow`). This matters for
  the upsert behavior in D5.

## Key decisions

### D1. Shared-origin storage collisions: change the storage keys in the prod copy (required, not cosmetic)

**The problem:**
- The prod Pages URL will be `https://datasciguycode.github.io/<prod-repo>/`. That is the **same
  origin** as dev, because an origin is scheme plus host, and the path doesn't count. So both apps
  share one `localStorage`, and within any one tab, one `sessionStorage`.
- `AuthState` stores its session under the fixed localStorage key `workflow-app.auth-session`.
- `index.html`'s build-id check guards itself with the fixed sessionStorage key `buildCheckDone`.

**What goes wrong with the auth key if we leave it:** signing into prod in a browser that's also
signed into dev overwrites dev's session with a prod token. Then:
- dev sends that token to dev Supabase,
- it gets 401 or the refresh fails,
- `SignOutAsync` runs, and it removes the shared key.

The result is that each site keeps logging the other out. It doesn't affect threadsinc1's device,
but it would badly confuse the owner's own testing, which is exactly the kind of "is dev broken?"
scare to avoid today.

**What goes wrong with `buildCheckDone` if we leave it:** sessionStorage is per origin *per tab*,
so separate tabs are fine, but **same-tab navigation** between dev and prod is not. If the owner
opens dev, then navigates the same tab to the prod URL (or vice versa), `buildCheckDone` is already
`"1"`, so the second site's one-time stale-build forced reload (added 2026-11-06 for the iOS
stale-cache complaints) silently never runs in that tab. Low severity (cache freshness only, no data
risk), but it's the exact bug class that mechanism exists to prevent.

**Fix (prod repo only, both one-line changes):**
- `web/Services/AuthState.cs`: `StorageKey` becomes `"workflow-app-prod.auth-session"`.
- `web/wwwroot/index.html`: both occurrences of `'buildCheckDone'` (the `getItem` and `setItem`
  lines) become `'buildCheckDone-prod'`.

Dev keeps its existing keys, so dev and prod no longer share either key, in either direction, with
no change to dev.

**Rejected alternatives:**
- A custom domain for prod. It's a real fix, but it needs a domain and DNS, which is out of scope
  today.
- Leaving it as is. It breaks side-by-side use.
- For `buildCheckDone`: storing the last-checked build id instead of a boolean (the sanity-check's
  other suggestion). It doesn't fully fix the collision on its own: dev's script would still read
  the flat `buildCheckDone` and be suppressed by prod unless dev were also changed, and changing dev
  is off the table today. A distinct key is a prod-only change that fixes both directions. A
  build-id-keyed guard is a reasonable later cleanup for both repos.

**iOS Home Screen web apps:** they *may* get separate storage containers, but we shouldn't rely on
that. Desktop Safari and Chrome definitely share storage.

### D2. Prod repo: a fresh clone from GitHub, push disabled toward dev

- Clone from `https://github.com/datasciguycode/workflow-engine.git` into a **sibling** directory:
  `/home/mmcbride/micah/claude/workflow-app-prod`.
  - **Not** inside the dev tree. The Supabase CLI searches upward for `supabase/`, and nested repos
    would be confusing.
  - Cloning from GitHub doesn't touch the dev working tree at all.
- Rename `origin` to `dev-upstream` and set its push URL to an invalid value. That way a stray
  `git push` from the prod clone can never land on dev, and `git fetch dev-upstream` still works
  later for promoting dev changes to prod.
- Keep the full history.
  - **Rejected:** squashing to a single "initial" commit. That loses the useful `git log` context
    that CLAUDE.md/PROGRESS.md lean on, and it makes future `dev-upstream` merges harder.
  - The history only contains dev's *publishable* key, which is designed to be public.
- **[USER DECISION: U1, repo name]** Default `workflow-engine-prod`; the user may prefer another.
  It must be **public**: Pages on private repos needs a paid GitHub plan, and dev is public anyway.
  The name becomes part of the URL, so changing it later means redoing the Supabase redirect URLs.
  If a different name is chosen, substitute it everywhere this plan says `workflow-engine-prod`
  (including the `/workflow-engine-prod/` base path and the Supabase URL Configuration).

### D3. Supabase project: new free-tier project, same org and region as dev

- Create `workflow-engine-prod` in org `swdeqnlbogugszsnyqlr`, region `us-west-2`, using
  `supabase projects create`.
- **[USER DECISION: U2, plan tier and org]** Free-tier projects auto-pause after about 7 days
  without activity. That's fine for a soft launch but not for real production. Upgrading to Pro is
  per-organization billing, and it would also start billing dev's project if both are in the same
  org.
  - If prod will be Pro, consider creating it in a **new org** instead, so dev stays free.
  - The plan's commands work either way. Only `--org-id` changes.

### D4. Schema replay: `supabase db push` from the prod clone, no seed

- Run `supabase link --project-ref <PROD_REF>` **inside the prod clone**. Link state lives in
  `supabase/.temp/` (gitignored) per working directory, so dev's link to `utwyvtbzesswpoihmlic` is
  untouched.
- Then run `supabase db push --dry-run`, followed by `supabase db push`.
- **Do not** use `--include-seed`. Dev's seed.sql is fixtures: isolation-test accounts, fixture user
  UUIDs that don't exist in prod's `auth.users`, the "Feature Pipeline" SDLC test workflow, and
  dummy items. Replaying it would create junk and broken foreign-key assumptions.
- **Do not** run `supabase config push`. It would push local config.toml values (site_url
  `127.0.0.1:3000`, etc.) onto prod's auth settings. Auth is configured in the dashboard (D6).
- **Rejected:** `pg_dump` of dev's schema restored into prod. That touches dev. It would also carry
  over any untracked drift instead of surfacing it, and the migration history table wouldn't line
  up with the repo.

### D5. Prod bootstrap data: a hand-written, prod-only SQL file, applied in two phases

- Leave `supabase/seed.sql` unchanged in the prod repo. It's only used by local `db reset`, and
  keeping it identical eases future dev-to-prod merges.
- Add `supabase/prod/bootstrap.sql`. It creates:
  1. one real account (a fresh `gen_random_uuid()`-style UUID, hardcoded in the file; **not** the
     `1111...` fixture UUIDs),
  2. the real workflow(s) and their stages, including `checklist` values,
  3. **no** `account_members`, items, or chat.
- **Re-run semantics (what "idempotent" means here):**
  - `accounts`: `on conflict (id) do nothing`. After the first run, this file never changes the
    account row again; rename the account with a one-off `update` if ever needed.
  - `workflows` and `stages`: `on conflict (id) do update set <mutable columns> = excluded.<col>`.
    So editing a stage's title, order, flags or `checklist` in the file and re-running **does**
    apply the edit. Keeping the file as the source of truth for prod's workflow definition is the
    point.
  - **Not handled by re-runs:** removing a stage from the file does not delete it from the database
    (and deleting a stage that items reference would fail anyway). Swapping two stages' titles in
    one run can trip `unique (workflow_id, title)`, and moving `is_initial` from one stage to
    another in one run can trip `stages_one_initial_per_workflow`. Do those as hand-written,
    ordered `update`s instead.
- Add `account_members` rows in a second step (`supabase/prod/add_member.sql`, a template filled in
  per run; see Step 5.5), after each person has signed into prod once. This is the same manual
  two-step pattern dev already uses, because `auth.users` rows only exist after first sign-in.

**[USER DECISION: U4, account name and workflows]** The likely default is "Joe's Auto Repair"
only, with stages `intake` through `payment_receipt_submitted` plus `closed`, using the same
titles, order, and `is_initial`/`is_terminal` flags as seed.sql. "Feature Pipeline" and the
isolation-test workflows are dev-only. The account's real business name also comes from the user.

**[USER DECISION: U5, where the checklist values come from]**
- **Option A, [USER DECISION: optional read-only dev touch]:** one `select` against dev:
  `supabase db query --project-ref utwyvtbzesswpoihmlic "select title, sequence_order, is_initial, is_terminal, checklist from public.stages where workflow_id = '33333333-3333-3333-3333-333333333330' order by sequence_order nulls last"`
  - It runs from **any directory other than the dev tree**, with an explicit ref.
  - It's a single read with no locks of note, and it can't affect the test session.
  - It's still "touching dev", so it's the user's call.
- **Option B (no dev touch):** the user dictates the checklist values.
- **Option C (no dev touch):** prod starts with `checklist` null, and the values are added to
  bootstrap.sql later and re-applied (the upsert in D5 makes that work). The agent treats
  checklists as soft hints anyway, per the migration comment.

**Rejected:**
- Copying dev's real jobs and items into prod. Prod starts clean, and dev data is test data.
- Putting the prod bootstrap into a migration. Migrations are schema shared by both environments,
  and prod data must never replay into dev.
- `do nothing` on every table (round 1). Safe to re-run, but edits silently don't take effect,
  which is a trap for whoever fixes a checklist typo weeks later.

### D6. Google OAuth: a new OAuth client in the same Google Cloud project; don't edit dev's client

- In the GCP project that holds dev's OAuth client, create a **new** OAuth 2.0 Client ID (Web
  application), named for example `workflow-engine-prod (Supabase)`. Give it one authorized
  redirect URI: `https://<PROD_REF>.supabase.co/auth/v1/callback`.
- **Rejected:** adding prod's callback to dev's existing client. It's additive and probably safe,
  but it means editing a resource dev's live sign-in depends on today. It also couples secret
  rotation for both environments.
- **Rejected:** a separate GCP project. That means a second consent screen, verification, and
  test-user list, which is overkill for now.
- **Nonce setting:** leave the Google provider's "Skip nonce check" **off** (the default). See A7
  for why, and for what's verified versus assumed.

**Caveat:** the consent screen is per GCP project, so it's shared.
- If it's in **Testing** publishing status, any prod user must be on its test-user list.
  - Adding test users is additive and doesn't affect dev.
  - **Don't** change the publishing status or the consent-screen branding today. That would
    affect dev.
- Check what status it's in. threadsinc1 got in today, so either it's published or they were
  added as a test user.

### D7. Edge Function: deploy only `agent-loop`, with its own Anthropic key

- Run `supabase functions deploy agent-loop --project-ref <PROD_REF>` from the prod clone.
  - Keep `verify_jwt` at its default (on). Dev proves it works with this project generation's
    keys.
- Set `ANTHROPIC_API_KEY` with `supabase secrets set --env-file supabase/.env --project-ref <PROD_REF>`.
  - Use the `.env` file rather than an inline value, which would land in shell history.
  - `supabase/.env` is gitignored by `supabase/.gitignore`. It won't exist in a fresh clone, so
    create it there.
- **[USER DECISION: U3, which Anthropic key]** Recommend a new, prod-dedicated Anthropic API key
  rather than reusing dev's. That gives separate usage visibility and spend limits, and rotating one
  key won't break the other.
  - If the user wants to reuse dev's key for now, the value can be copied from dev's
    `supabase/.env` by **reading** the file. That's a read of an untracked file and doesn't affect
    the tree.

### D8. Pages: enable via `gh api` before the first push, then push the prod-edited commit

- Create the repo empty, enable Pages with `build_type=workflow`, then push.
- The **first** push must already contain the prod `SupabaseConfig` values. Otherwise the very
  first prod Pages deploy would ship an app wired to **dev's** backend, and anyone who opened it
  would be reading and writing dev data.
- So the Supabase project must exist (Step 2) before the code edits (Step 5).
- Sanity-check confirmed the explicit `gh api` enable is necessary: `configure-pages@v6` defaults
  `enablement` to false, and the workflow's `GITHUB_TOKEN` lacks `administration:write` anyway.

## Assumptions (unverified)

- **A1. Pages on an empty repo.** `POST /repos/{owner}/{repo}/pages` with `build_type=workflow`
  succeeds on a repo with no commits yet. GitHub's docs are inconsistent on whether `source` is
  required. If it 422s, the fallback is in Step 6.
- **A2. New-project defaults match dev's.** A project created today has the same API-key and JWT
  defaults as dev, created 2026-09-19. That means `SUPABASE_ANON_KEY` is still injected into Edge
  Functions, and the gateway's `verify_jwt` accepts the project's user JWTs. Supabase docs say
  legacy keys are being phased out "by end of 2026". If a project created in Nov 2026 lacks
  `SUPABASE_ANON_KEY`, `agent-loop` would send `apikey: undefined` and every REST call would 401.
  Two checks catch this: Step 7's `supabase secrets list` check (is `SUPABASE_ANON_KEY` listed?)
  and the Verification checklist's "Agent chat: direct call before the UI" curl check. The fallback
  edit is in Risks ("A2 fallback").
- **A3. No out-of-band drift.** Dev's schema contains nothing that isn't in `supabase/migrations/`
  (no out-of-band DDL, grants, or functions). Given the history (grant fixes were turned into
  migrations), that's likely true but not proven. Prod verification exercises every RPC the UI and
  agent use, which is the practical drift test.
  - **[USER DECISION: optional read-only dev touch]** A stronger check, best run after today's
    session: `supabase db dump --schema public,private --project-ref ...` against both projects,
    then diff.
- **A4. Data API defaults.** The new project's Data API is enabled and exposes `public`, as the
  dashboard does by default. If the creation flow offers "automatically expose new tables" or a
  Data API toggle, keep the Data API on. Exposure-by-default doesn't matter, because migrations
  grant explicitly.
- **A5. OAuth client access.** The owner has access to the GCP project holding dev's OAuth client.
- **A6. Repo name.** The repo name `workflow-engine-prod` is acceptable. See D2,
  **[USER DECISION: U1]**.
- **A7. "Skip nonce check" off is correct for this app's sign-in flow.** Partially verified.
  - What's checked: the setting governs whether Supabase Auth accepts a Google **ID token** whose
    nonce it can't match. Community and third-party guides (not an official Supabase docs page)
    describe it as a workaround for native/ID-token sign-in (`signInWithIdToken`, e.g. native iOS
    SDKs that don't expose the nonce), and recommend leaving it off otherwise. The local
    `config.toml` comment ("Required for local sign in with Google auth") points the same way.
  - What's assumed: this app uses the hosted redirect flow (`AuthState` redirects to
    `/auth/v1/authorize?provider=google`, and Supabase Auth itself does the code exchange with
    Google server-side), so the setting shouldn't come into play, and "off" is the safer value. Not
    confirmed against current official Supabase docs.
  - How it would show up: Step 8.2's first sign-in fails with a nonce-related error on the Supabase
    callback. Only then consider turning it on, and record why in prod PROGRESS.md.

## Implementation steps

Placeholders: `<PROD_REF>`, `<PROD_PUBLISHABLE_KEY>`, `<PROD_URL>` =
`https://datasciguycode.github.io/workflow-engine-prod/`.

**Before Step 2, get answers to U1 (repo name) and U2 (tier and org).** U3-U5 can wait until their
steps.

**Every Supabase command below runs from `/home/mmcbride/micah/claude/workflow-app-prod`, never from
the dev directory.**

### Step 1. Clone the prod working copy (no dev-tree contact)

```bash
git clone https://github.com/datasciguycode/workflow-engine.git /home/mmcbride/micah/claude/workflow-app-prod
cd /home/mmcbride/micah/claude/workflow-app-prod
git remote rename origin dev-upstream
git remote set-url --push dev-upstream DISABLED-do-not-push-prod-to-dev
git remote -v   # confirm the push URL is the DISABLED one
```

Check that `supabase/.temp/` does **not** exist in the clone. It's gitignored, so it shouldn't.
That confirms nothing is linked yet.

### Step 2. Create the prod Supabase project

**[USER DECISION: U1, U2]** must be answered first.

```bash
supabase projects create workflow-engine-prod \
  --org-id swdeqnlbogugszsnyqlr --region us-west-2 --db-password '<generated, store in password manager>'
supabase projects list            # note <PROD_REF>; wait for ACTIVE_HEALTHY
supabase projects api-keys --project-ref <PROD_REF> -o json   # note sb_publishable_... key
```

- Use a different `--org-id` if U2's answer is "new org".
- Store the DB password in the password manager, not in the repo.
- While you're in `api-keys`, note whether a legacy `anon` key is listed. If none is, A2 is at
  risk, so look at the A2 fallback in Risks before Step 7.

### Step 3. Link the clone and replay migrations

```bash
supabase link --project-ref <PROD_REF>          # in the prod clone only
cat supabase/.temp/project-ref                   # must print <PROD_REF>, not utwyvtbzesswpoihmlic
supabase db push --dry-run                       # expect all 12 migrations listed, nothing else
supabase db push
supabase migration list --linked                 # local and remote columns match, 12 rows
```

Smoke-check the schema without auth:

```bash
supabase db query --project-ref <PROD_REF> "select table_name from information_schema.tables where table_schema='public' order by 1"
# expect: account_members, accounts, chat_messages, item_events, items, stages, workflows
supabase db query --project-ref <PROD_REF> "select grantee, privilege_type, table_name from information_schema.role_table_grants where grantee='authenticated' and table_schema='public' order by 3,2"
```

### Step 4. Configure Auth on the prod project (dashboard)

**Google Cloud console (D6):**
- Create the new OAuth client, with redirect URI
  `https://<PROD_REF>.supabase.co/auth/v1/callback`.
- If the consent screen is in Testing, add any prod users as test users.

**Supabase dashboard, prod project, Authentication:**
- **Sign In / Providers → Google:**
  - enable it,
  - paste the new client ID and secret,
  - leave "Skip nonce check" off (A7).
- **Sign In / Providers → Email:** disable it. The app only uses Google. Leaving email on means
  anyone holding the public publishable key can create `auth.users` rows via `/auth/v1/signup`.
  That's harmless under RLS (no membership means no data), but it's needless clutter.
  - Keep "Allow new users to sign up" **on**. Google first sign-in needs it to create the user.
- **URL Configuration:**
  - **Site URL:** `https://datasciguycode.github.io/workflow-engine-prod/`
  - **Redirect URLs:** `https://datasciguycode.github.io/workflow-engine-prod/**`
    - `AuthState.SignInWithGoogle` sends `redirect_to = NavigationManager.BaseUri`. On Pages, after
      the CI base-href rewrite, that's exactly `<PROD_URL>`. The `**` wildcard just tolerates
      future variation.
  - Do **not** add the dev URL. Do **not** add localhost unless you plan to run the prod repo
    locally against prod.

### Step 5. Make the prod-only code edits in the clone

1. **`web/Services/WorkflowApiClient.cs`, `SupabaseConfig`:** set `ApiUrl` to
   `"https://<PROD_REF>.supabase.co"` and `PublishableKey` to `<PROD_PUBLISHABLE_KEY>`. Update the
   comment above it to say "prod project workflow-engine-prod".
2. **Shared-origin storage keys (D1):**
   - `web/Services/AuthState.cs`: set `StorageKey` to `"workflow-app-prod.auth-session"`, with a
     one-line comment explaining the shared github.io origin.
   - `web/wwwroot/index.html`: change both `'buildCheckDone'` occurrences (lines 42-43 in the
     current file) to `'buildCheckDone-prod'`, and add a one-line note to the existing comment
     block saying why.
3. **Optional, recommended:** so prod and dev Home Screen icons and tabs can be told apart:
   - In `web/wwwroot/manifest.webmanifest`, set `name`/`short_name` to e.g. `Workflow Engine`.
   - In `web/wwwroot/index.html`, set `<title>` to the same value, e.g.
     `<title>Workflow Engine</title>` (currently `WorkflowApp.Web`). Keeping tab title and Home
     Screen name identical avoids a third name floating around.
   - Dev stays "WorkflowApp.Web", since it isn't touched.
   - Icons are unchanged.
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

   - Use literal, pre-generated UUIDs throughout (generate them once, e.g. with `uuidgen`, and
     paste them in), so re-runs hit the same rows.
   - Don't include `account_id` in the workflow upsert's `set` list; a workflow never moves
     accounts via this file.
   - Check the exact column names against migrations before running (e.g. whether `workflows` has
     other not-null columns without defaults).
5. **`supabase/prod/add_member.sql`:** a committed **template** that is never edited in place.
   It uses `psql`-style named placeholders in a fixed format so it can be filled mechanically:

   ```sql
   -- TEMPLATE. Don't run directly and don't edit in place. See PROGRESS.md "Adding a prod member".
   insert into public.account_members (account_id, user_id, role, display_name)
   select '<new-uuid-A>', id, '__ROLE__', '__DISPLAY_NAME__'
   from auth.users where email = '__EMAIL__'
   on conflict (account_id, user_id) do nothing
   returning account_id, user_id, role;
   ```

   - `<new-uuid-A>` is the real account UUID, filled in **once** when the file is created (it
     never varies per run). Only `__ROLE__`, `__DISPLAY_NAME__` and `__EMAIL__` vary.
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

     - The filled copy lives outside the repo, so the template stays clean in git and nobody
       commits someone's email by accident.
     - `role` is `owner` or `member`. Display names containing `'` must be doubled (`O''Brien`);
       names containing `/` or `&` need escaping for sed, so for those just edit the scratch copy
       by hand instead.
   - This looks up the user id by email, which avoids copy-pasting UUIDs. The `returning` clause
     should print 1 row; 0 rows means either the person hasn't signed in yet or they're already a
     member.
   - **Rejected:** `psql -v email=...` variable substitution. `supabase db query` isn't psql and
     doesn't support `-v`, and adding a psql dependency just for this isn't worth it.
6. **`PROGRESS.md` and `CLAUDE.md`:**
   - Replace PROGRESS.md with a prod snapshot: prod project ref, prod URL, the two deploy paths
     (the functions deploy now targets `<PROD_REF>`), the "Adding a prod member" procedure (the
     sed fill-and-run block above), and any divergence from dev (the D1 storage keys, and the A2
     fallback if applied).
   - Add a short note at the top of CLAUDE.md: "This is the PROD repo; dev is
     datasciguycode/workflow-engine. Always pass `--project-ref <PROD_REF>` to Supabase commands."
7. **Verify the edits:**
   - `grep -rn utwyvtbzesswpoihmlic web/` should print nothing.
   - `grep -n buildCheckDone web/wwwroot/index.html` shows only `buildCheckDone-prod`.
   - `dotnet build web/WorkflowApp.Web.csproj` should succeed.
   - Commit, but don't push yet.

### Step 6. Create the GitHub repo, enable Pages, push

```bash
gh repo create datasciguycode/workflow-engine-prod --public \
  --description "Workflow Engine (production)"     # no --source/--push yet
gh api -X POST repos/datasciguycode/workflow-engine-prod/pages -f build_type=workflow
git remote add origin https://github.com/datasciguycode/workflow-engine-prod.git
git push -u origin main
gh run watch --repo datasciguycode/workflow-engine-prod
gh api repos/datasciguycode/workflow-engine-prod/pages --jq '.html_url,.build_type'
```

- The push triggers `deploy-pages.yml`, because the path filter matches `web/**` on a first push.
- `configure-pages` derives `base_path=/workflow-engine-prod` from the repo, so the base-href
  rewrite and 404.html (`pathSegmentsToKeep = 1`) work unchanged.
- **If the Pages POST 422s on the empty repo (A1):**
  1. Push first. The first workflow run will fail at `configure-pages`.
  2. Then run the `gh api` POST.
  3. Then `gh workflow run deploy-pages.yml --repo datasciguycode/workflow-engine-prod`.
  - The failed run deployed nothing, so there's no harm.
- **Don't** copy dev's repo settings or secrets. The workflow needs none: it uses only
  `GITHUB_TOKEN` and OIDC.

### Step 7. Deploy `agent-loop` and set its secret

**[USER DECISION: U3, which Anthropic key]** must be answered first.

```bash
printf 'ANTHROPIC_API_KEY=%s\n' '<prod key>' > supabase/.env   # gitignored; verify with git status
git status --short supabase/                                     # .env must NOT appear
supabase secrets set --env-file supabase/.env --project-ref <PROD_REF>
supabase functions deploy agent-loop --project-ref <PROD_REF>    # name it explicitly; never bare deploy
supabase functions list --project-ref <PROD_REF>                 # exactly one function: agent-loop
supabase secrets list --project-ref <PROD_REF>                   # ANTHROPIC_API_KEY present (+ platform SUPABASE_*)
```

Check two things:
- In `secrets list`, `SUPABASE_ANON_KEY` should appear among the platform-provided names. If it's
  absent, apply the A2 fallback (Risks) **including its redeploy** before Step 8.
- If `supabase functions list` shows `mcp-server`, delete it immediately:
  `supabase functions delete mcp-server --project-ref <PROD_REF>`.

### Step 8. Bootstrap data and first owner

1. `supabase db query --project-ref <PROD_REF> -f supabase/prod/bootstrap.sql`
2. The owner opens `<PROD_URL>` and signs in with Google. The app should show **no workflows**:
   that's correct, because RLS gives no membership, no rows. (If sign-in fails with a nonce error,
   see A7.)
3. Fill and run `add_member.sql` for the owner using the sed fill-and-run block in Step 5.5, with
   `__ROLE__` = `owner`. Expect 1 row returned. Reload, and the workflow should appear.
4. **[USER DECISION: U7, who gets prod access]** Additional prod users follow the same two steps:
   they sign in, then you fill and run the template for them with `__ROLE__` = `member` (or
   `owner`). **Don't** automatically add threadsinc1 to prod.

## Verification checklist

**How to read this:** every item under **Required** must pass before calling prod live. Items under
**Recommended** are each the user's call (they touch dev read-only, or need a dev session); skipping
one doesn't block go-live, but the listed consequence applies.

### Required

**Sign-in and session:**
- [ ] **Sign-in round trip.** On desktop and iPhone Safari, the flow goes Google, then back to
  `<PROD_URL>`, with the fragment stripped and the email shown. Separately, a redirect to the
  Site URL with an error, or to the dev URL, means the allowlist is wrong.
- [ ] **Session persistence.** A hard reload while signed in stays signed in.
- [ ] **Token refresh works.** Either leave a tab open for more than an hour and then act, or force
  it: in devtools, edit the localStorage `expires_at` for `workflow-app-prod.auth-session` to a
  past value, reload, and act. Expect no sign-out, and a POST to `/auth/v1/token?grant_type=refresh_token`
  on **prod's** ref.

**Routing and build:**
- [ ] **Deep-link refresh.** Open a workflow, then a job, so the URL is
  `/workflow-engine-prod/workflow/<id>/...`. Hard refresh and you should land on the same screen,
  not a 404 or white screen. Do the same from a pasted URL in a fresh tab.
- [ ] **Build id stamped.** View source of `<PROD_URL>`: `<meta name="build-id">` is not `dev`,
  `<base href="/workflow-engine-prod/" />`, and the build-check script uses `buildCheckDone-prod`.
- [ ] **No dev host in the shipped bundle.** In the browser network tab, every
  `rest/v1`, `auth/v1` and `functions/v1` request goes to `<PROD_REF>.supabase.co`, never to
  `utwyvtbzesswpoihmlic`.

**Agent chat (agent-loop):**
- [ ] **Direct call before the UI.** `curl -i -X OPTIONS https://<PROD_REF>.supabase.co/functions/v1/agent-loop`
  returns CORS headers. A POST with a real prod user JWT (copied from localStorage) and a minimal
  body returns 200 with a reply, not 401 or 500.
  - **401 from the gateway** means a `verify_jwt` or key-generation problem (A2).
  - **500 with an Anthropic auth error** means a bad key. That's the same failure seen on dev's
    first live run.
- [ ] **In the UI.** On the New Job screen, send a create-job message. The agent replies, the job
  appears in the list, and its history shows an event. That proves `create_item`, the
  `item_events` insert and the sequence grant, and that `chat_messages` persist.
- [ ] **Complete Stage.** "Complete Stage" and a field-update message both work. That covers
  `move_stage` and `update_data`.
- [ ] **Anthropic usage.** The Anthropic console shows usage on the **prod** key.

**Isolation:**
- [ ] **Within prod (RLS).** A second Google account that has signed in but has **no**
  `account_members` row sees zero workflows and jobs, and its agent chat can't act on the owner's
  workflow. Also check directly:
  `curl "https://<PROD_REF>.supabase.co/rest/v1/workflows" -H "apikey: <PROD_PUBLISHABLE_KEY>" -H "Authorization: Bearer <non-member JWT>"`
  should return `[]`.
- [ ] **Anonymous.** The same request with only the publishable key (no user JWT) returns `[]` or
  401, not rows.
- [ ] **Prod data never in dev.** By construction, dev's database never received prod data: no
  command in this plan targets dev's ref.
- [ ] **Membership doesn't carry over.** Dev memberships don't exist in prod. If threadsinc1 (or the
  owner's dev identity) signs into prod before being added, they see nothing. Their prod
  `auth.users` id will differ from their dev id.

**Dev unaffected (final check):**
- [ ] **Dev still works.** As a normal user, dev Pages still loads and signs in. (This is a normal
  user visit, not an admin touch, so it's required.)
- [ ] **No git or link changes in dev.** `git -C /home/mmcbride/micah/claude/workflow-app status`
  shows only the untracked `plans/prod-instance-setup/` directory, and
  `cat /home/mmcbride/micah/claude/workflow-app/supabase/.temp/project-ref` still prints
  `utwyvtbzesswpoihmlic`.

### Recommended (each is a **[USER DECISION: optional read-only dev touch]**)

- [ ] **Shared-origin coexistence (D1).** In one desktop browser, sign into dev and into prod in two
  tabs. Reload both: each stays signed in as its own environment. Then, in one tab, go dev → prod
  URL and check in devtools that `buildCheckDone-prod` gets set (prod's build check ran despite
  dev's `buildCheckDone` being present). This is a normal-user visit to dev.
  - If skipped: side-by-side dev/prod use in one browser is unverified. Do it before relying on
    that.
- [ ] **Cross-project, prod token against dev.** Send a prod user JWT to **dev** REST:
  `curl "https://utwyvtbzesswpoihmlic.supabase.co/rest/v1/workflows" -H "apikey: <dev publishable key>" -H "Authorization: Bearer <prod JWT>"`
  It should return 401 (signature or issuer mismatch). It's a single rejected read with zero
  effect on dev.
  - **Converse:** a dev JWT against prod REST returns 401. This one sends nothing to dev; it only
    needs a dev token copied out of a browser that's already signed in.
  - If skipped: cross-project token rejection rests on Supabase's per-project signing keys, which
    is a platform guarantee rather than something we observed.

## Risks and edge cases

**Shipping a prod build wired to dev.** If the Step 5 edits are skipped or partially missed, the
prod site reads and writes **dev** data, including the test user's real jobs. This is the single
worst failure.
- Mitigations: the `grep` check in Step 5.7, ordering the first push after the edits (D8), and the
  network-tab check in verification.

**`supabase` commands hitting the wrong project.**
- Every remote command passes `--project-ref <PROD_REF>` or runs only after the
  `cat supabase/.temp/project-ref` check in the prod clone.
- Never run Supabase commands from the dev directory during this task. The CLI's upward
  directory search means a `cd` slip would silently use dev's link.

**A2 fallback: no `SUPABASE_ANON_KEY` in the function environment.**
1. In the prod repo only, change line 25 of `supabase/functions/agent-loop/index.ts` to
   `Deno.env.get("SUPABASE_ANON_KEY") ?? <first key from JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"))>`.
   Verify the exact shape of `SUPABASE_PUBLISHABLE_KEYS` from `secrets list` or the docs at that
   point.
   - Alternatively, set a custom secret `PUBLISHABLE_KEY` (add it to `supabase/.env` and re-run
     `supabase secrets set --env-file supabase/.env --project-ref <PROD_REF>`) and read that.
2. **Redeploy** so the edit takes effect:
   `supabase functions deploy agent-loop --project-ref <PROD_REF>`. Editing the file alone changes
   nothing; the 401s persist until this runs.
3. Re-run the Verification "Direct call before the UI" curl check; expect 200.
4. Commit the change in the prod repo and record the divergence from dev in the prod PROGRESS.md.

**A2 variant: gateway rejects ES256 user JWTs with `verify_jwt` on.**
- Third-party reports exist, but this is unconfirmed, and dev's identical setup works.
- Fallback: deploy with `--no-verify-jwt`. **Only** do that together with an in-function
  `getClaims` or JWT check. Even without one, the function forwards the JWT to PostgREST, which
  enforces RLS, so writes stay protected. But don't ship a no-verify function without stating that
  reasoning.

**Free-tier auto-pause (D3).**
- A paused prod project means the app silently fails to load data.
- Decide on Pro (or a scheduled keep-alive) before real users depend on it (U2).

**Google consent screen shared with dev.**
- Editing branding, scopes, or publishing status affects dev's sign-in.
- This plan only adds a client and, possibly, test users.

**bootstrap.sql re-runs (D5).** Re-running applies workflow/stage edits but never deletes stages,
and title swaps or `is_initial` moves can hit unique constraints. The file header says so.

**add_member template leakage.** The fill-and-run pattern writes the filled copy to `/tmp` and
deletes it. If someone edits `supabase/prod/add_member.sql` in place instead, `git status` will
show it modified; revert with `git checkout -- supabase/prod/add_member.sql` rather than committing
an email address.

**Service worker. [USER DECISION: U8]**
- index.html's comment says to "re-enable before the real production deploy".
- This plan deliberately **does not** re-enable it. The stale-cache problems on iOS that the
  build-id reload fixes would come back, and offline support isn't a stated prod requirement.
- Flagged for the user to acknowledge rather than silently skipped.

**Repo name change later.** It would change the URL, which means updating the Supabase Site URL
and Redirect URLs, and any Home Screen icons would need re-adding. Settle U1 before Step 2.

**Rollback.** Everything is new and separate:
- `gh repo delete datasciguycode/workflow-engine-prod`,
- delete or pause the Supabase project from the dashboard,
- delete the new OAuth client,
- `rm -rf /home/mmcbride/micah/claude/workflow-app-prod`.

None of it affects dev.

## Out of scope (deliberate)

- **Config indirection.** Moving the Supabase URL/key out of hardcoded C# is deferred per the task.
- **Promotion workflow.** A dev-to-prod promotion process (`git fetch dev-upstream` then merge,
  re-running `db push` and `functions deploy` against prod) is enabled by D2's remote setup but not
  designed here. Note that merges will need to keep prod's D1 storage keys.
- **Admin UI** for accounts and members.
- **Custom domain** for prod. It would also be the cleaner long-term fix for D1.
- **Re-enabling the service worker** or offline PWA support.
- **Build-id-keyed `buildCheckDone` guard** for both repos (D1 rejected alternative). A later
  cleanup, done in dev first and then promoted.
- **Dev bookkeeping.** Updating dev's PROGRESS.md and CLAUDE.md to mention that prod exists, and
  committing or pushing dev's unpushed `390fc11`. Do these **after** today's test session, in the
  dev tree, as a separate small change.
- **Prod operations.** Backups and PITR, monitoring, and alerting for prod.
- **Migrating real dev data** (jobs, chat history) into prod.

## Feedback from this round

**Plan-reviewer**

1. *"All must pass" header contradicts optional items.* **Adopted.** The checklist is now split
   into **Required** (all must pass) and **Recommended** (each a user decision with a stated
   consequence if skipped). The D1 coexistence test and the cross-project token test (plus its
   converse) moved to Recommended. "Dev still works" stays Required, since it's a normal-user
   visit and is the core safety check.
2. *Dangling "Step 7's curl check" reference in A2.* **Adopted.** A2 now names both real checks:
   Step 7's `secrets list` check and the Verification "Direct call before the UI" curl check.
3. *A2 fallback omits the redeploy.* **Adopted.** The fallback is now a numbered sequence: edit,
   **redeploy** `agent-loop`, re-run the curl check, commit and record the divergence. Step 7 also
   says "including its redeploy". The custom-secret alternative now also says to re-run
   `secrets set`.
4. *`<title>` has no target value.* **Adopted.** Step 5.3 gives `<title>Workflow Engine</title>`,
   matching the manifest name, with the current value noted.
5. *Inconsistent user-decision markers.* **Adopted.** Every decision point now uses
   **[USER DECISION: ...]**, including the dev-touch ones (`[USER DECISION: optional read-only dev
   touch]`), so one grep finds all of them. Also added a "User decision points" table (U1-U8) near
   the top, saying when each is needed. Two points that were implicit in round 1 are now explicit:
   U3 (which Anthropic key) and U8 (service worker stays off).
6. *No mechanism for filling `add_member.sql`.* **Adopted.** It's now a never-edited-in-place
   template with `__EMAIL__`/`__ROLE__`/`__DISPLAY_NAME__` tokens. The account UUID is filled once.
   There's a documented sed fill → leftover-token grep → run → delete block, copied into prod
   PROGRESS.md. It gained `returning` so the 1-row/0-row outcome is visible. I rejected `psql -v`
   because `supabase db query` isn't psql.

**Sanity-check**

1. *`buildCheckDone` same-tab collision.* **Adopted, with a different fix than either option
   offered.** D1 now explains the same-tab failure. Prod renames the key to `buildCheckDone-prod`
   (Step 5.2), with grep and view-source checks added. I rejected the build-id-keyed guard as
   *today's* fix: on its own in prod, it doesn't stop prod from suppressing dev's check, because
   dev still reads the flat key, and fixing dev is off-limits today. A distinct key fixes both
   directions with a prod-only change. The build-id guard is listed as a later cleanup in Out of
   scope.
2. *bootstrap.sql "idempotent" conflates re-run safety with edits applying.* **Adopted the
   upsert option.** `accounts` stays `do nothing`; `workflows` and `stages` use
   `on conflict (id) do update set ...` for mutable columns, so edits apply on re-run. Since the
   upsert has its own limits, D5, the SQL header and Risks now spell them out: no deletes, and
   `unique (workflow_id, title)` / `stages_one_initial_per_workflow` can trip on title swaps or
   `is_initial` moves. Those are verified constraints in the migrations.
3. *Nonce claim asserted without verification.* **Adopted both halves.** I checked it as far as
   available sources allow. Third-party and community docs describe "Skip nonce check" as an
   ID-token / native-flow workaround to leave off otherwise, and the local `config.toml` comment
   agrees. I found no official Supabase page that settles it. So it's now **A7**, which says what's
   checked, what's assumed, and the symptom (a nonce error at Step 8.2's first sign-in) that would
   trigger revisiting it. D6 and Step 4 point to A7 instead of asserting.
4. *A1 confirmation (no action needed).* Noted. A1 now mentions the docs inconsistency, and D8
   cites sanity-check's confirmation that the explicit Pages enable is necessary.
