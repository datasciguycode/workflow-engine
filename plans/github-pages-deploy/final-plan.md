# GitHub Pages deploy for the Blazor WASM app (`web/`): final plan

**Verdict: `approved-with-changes`.** The round-1 draft is sound and buildable. The changes are
corrections and clarifications, not redesign. The adjudication notes at the end list each one.
The two things to flag before building: (1) **Supabase Auth's Redirect URL must be updated by
hand, or Google sign-in on Pages breaks**; (2) the sanity check's `.nojekyll` hedge is
**rejected**, because `upload-pages-artifact` strips dotfiles by default, so the proposed
`touch` would never reach the site anyway.

---

## Goal

Deploy `web/` (Blazor WASM, `net10.0`) to **`https://datasciguycode.github.io/workflow-engine/`**
on every push to `main` that touches the app. Deep links such as `/workflow-engine/workflow/<id>`
must survive a hard refresh, and Google sign-in must round-trip back to the Pages URL.

## Grounding (verified 2026-11-01)

- **Repo:** `datasciguycode/workflow-engine`. It's public, the default branch is `main`, and
  Pages isn't enabled yet. There's no `CNAME` and no custom domain. So the base path is
  `/workflow-engine/`.
- There's **no `.github/` directory and no CI.** There's also no `.sln` and no `global.json`.
  The local SDK is 10.0.402.
- **Project:** `web/WorkflowApp.Web.csproj` uses `Microsoft.NET.Sdk.BlazorWebAssembly` with
  `OverrideHtmlAssetPlaceholders=true` (.NET 10 fingerprinting plus import map).
- **`web/wwwroot/index.html`** has `<base href="/" />`. Every other asset reference is relative.
  The service worker registration is commented out.
- **Publish:** `dotnet publish web/WorkflowApp.Web.csproj -c Release -o <out>` succeeds without
  the `wasm-tools` workload (it only warns).
  - Output goes to `<out>/wwwroot/`, about 20 MB including `.br`/`.gz` siblings.
  - `<base href="/" />` survives publish unchanged.
  - The import map uses `./`-relative keys, so it isn't affected by a base-href rewrite.
  - A grep over the whole publish output for root-absolute references (`"/_`, `href="/`,
    `src="/`) finds only the `<base>` tag and the `app.css` `@import` (fixed below).
- **Action versions** (latest releases, confirmed against each `action.yml`):
  - `actions/checkout` v7
  - `actions/setup-dotnet` v6
  - `actions/configure-pages` v6, which declares a `base_path` output: `"/repo"`, or `""` on a
    custom domain or user page
  - `actions/upload-pages-artifact` v5, which excludes dotfiles unless `include-hidden-files: true`
  - `actions/deploy-pages` v5

  This matches Microsoft's own reference workflow (`dotnet/blazor-samples` `static.yml`) almost
  line for line.
- **Runtime config:** `SupabaseConfig` in `web/Services/WorkflowApiClient.cs` hardcodes absolute
  Supabase URLs, so it doesn't depend on the base path. No change is needed.
- **OAuth:** `AuthState.SignInWithGoogle()` sends `redirect_to = NavigationManager.BaseUri`,
  which on Pages is `https://datasciguycode.github.io/workflow-engine/`.
  - The flow is GoTrue implicit: Google → Supabase `/auth/v1/callback` →
    `redirect_to#access_token=…`.
  - `StripFragment()` uses `GetLeftPart(Path)`, which keeps the subpath.
  - Both behave correctly under a subpath.
- **CORS:** `agent-loop` sends `Access-Control-Allow-Origin: *`, and Supabase cloud
  PostgREST/GoTrue accept any origin. No change is needed.
- **Routes:** `/`, `/workflow/{WorkflowId}`, and `/not-found`. `App.razor` uses
  `Router NotFoundPage="typeof(Pages.NotFound)"`.
- **`FluentLink`** (FluentUI Blazor) renders a `<fluent-link href=…>` custom element, not a
  plain `<a>`. That's fine for two reasons:
  - Relative `href` resolution against `<base>` is document-wide.
  - With `ForceLoad=false` (the default), the component uses Blazor's built-in navigation.

### Subpath bugs in app code (must fix)

1. `web/Pages/Home.razor:56`: `Nav.NavigateTo($"/workflow/{workflowId}")`. The leading `/`
   resolves against the host root, so navigation leaves the app.
2. `web/Pages/WorkflowDetail.razor:30`: `<FluentLink Href="/" …>` has the same problem.
3. `web/wwwroot/css/app.css:1`: `@import url('/_content/…/reboot.css')` is absolute, so it 404s
   under the subpath. It's also redundant, because `index.html` already links the same file
   relatively and before `app.css`.

All three fixes below also work at the local dev root (`/`).

## Decisions

### D1. Base href: keep `/` in source; rewrite it in CI from `configure-pages`' `base_path`

- Local `dotnet run` / `dotnet watch` keep working unchanged.
- CI rewrites the published `index.html` to `<base href="${base_path}/" />`.
  - On this project page that gives `/workflow-engine/`.
  - On a future custom domain it gives `/` automatically.
- A `grep -c` assertion fails the job if the rewrite didn't land, so a drifted tag format fails
  CI instead of deploying a white screen.
- Editing `index.html` after publish is safe:
  - Integrity hashes cover `_framework` JS only.
  - The stale `index.html.br`/`.gz` siblings are never requested (see D4).
- **Rejected alternatives:**
  - Hardcoding `/workflow-engine/` in source breaks local dev.
  - `StaticWebAssetBasePath` solves a different problem.
  - Computing `<base>` at runtime in JS is fragile alongside the import-map placeholders.
  - `SteveSandersonMS/ghaction-rewrite-base-href`, which Microsoft's doc uses, adds a
    third-party trust dependency, needs SHA pinning, and needs an extra repo setting to allow it,
    for the same result as one `sed` plus an assertion.

### D2. SPA fallback: the rafgraph `spa-github-pages` redirect

- `web/wwwroot/404.html` encodes the unknown path into the query string (`?/workflow/abc`) and
  redirects to the app root.
- A decoder in `index.html` restores the real URL with `history.replaceState` before Blazor
  boots.
- Deep links get an HTTP 200 for the final document. The cost is one extra round trip.
- **Rejected:** copying `index.html` to `404.html` in CI. It's simpler, but every deep-link load
  returns HTTP 404, and it leaves a second divergent copy of `index.html`.
- **This decision is closed.**

### D3. Workflow shape: GitHub's official two-job artifact deploy

- The `build` job uploads with `upload-pages-artifact`; the `deploy` job runs `deploy-pages`.
- Use major-version tags rather than SHA pins. These are first-party `actions/*` actions in a
  solo public repo.
- **Rejected:** `peaceiris/actions-gh-pages` with a `gh-pages` branch. It's legacy, it commits
  build output into history, and it needs `contents: write`.

### D4. No `.nojekyll`, no compression changes

- With Pages Source = "GitHub Actions", the uploaded artifact is served as-is and Jekyll never
  runs. `_framework/` and `_content/` are served normally. Microsoft's reference workflow, which
  uses the same three actions, ships no `.nojekyll` and works.
- Adding `.nojekyll` wouldn't help anyway. `upload-pages-artifact` v5 tars with `--exclude=.[^/]*`
  unless `include-hidden-files: true` is set, so a `.nojekyll` in `publish/wwwroot` is silently
  dropped from the artifact.
- The `.br`/`.gz` sidecars are unused bytes. The import map and `<script src>` point at the
  uncompressed files, and Pages doesn't negotiate precompressed sidecars. Leave them in place;
  wiring up Brotli via `loadBootResource` is out of scope.

## Implementation steps

### Step 1: Fix the subpath-unsafe links

- `web/Pages/Home.razor:56`: change to `Nav.NavigateTo($"workflow/{workflowId}");`
- `web/Pages/WorkflowDetail.razor:30`: change to `<FluentLink Href="./" Class="back-link">`.
  Use `"./"` rather than `""`, because some components treat an empty `Href` as "no link".
- `web/wwwroot/css/app.css:1`: delete the `@import url('/_content/…reboot.css');` line.
  Don't make it relative: CSS `@import` resolves against the stylesheet URL, and the duplicate
  load isn't wanted.
- Verify with `dotnet run` at `/`: Home → open a workflow → back link. Each step should still
  work.

### Step 2: Add `web/wwwroot/404.html`

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Workflow Engine</title>
  <script>
    // GitHub Pages SPA fallback (rafgraph/spa-github-pages). Pages serves this file for any
    // unknown path; we bounce to the app root with the original path encoded in the query
    // string, and index.html's decoder restores it before Blazor boots.
    // pathSegmentsToKeep = 1 because this is a project page (/workflow-engine/...).
    // Set to 0 if the site ever moves to a custom domain / user page at the root.
    var pathSegmentsToKeep = 1;
    var l = window.location;
    l.replace(
      l.protocol + '//' + l.hostname + (l.port ? ':' + l.port : '') +
      l.pathname.split('/').slice(0, 1 + pathSegmentsToKeep).join('/') + '/?/' +
      l.pathname.slice(1).split('/').slice(pathSegmentsToKeep).join('/').replace(/&/g, '~and~') +
      (l.search ? '&' + l.search.slice(1).replace(/&/g, '~and~') : '') +
      l.hash
    );
  </script>
</head>
<body></body>
</html>
```

Publish copies it to the site root next to `index.html`. It has no asset placeholders, so
.NET 10's HTML placeholder processing leaves it alone.

### Step 3: Edit `web/wwwroot/index.html`

1. Leave `<base href="/" />` as is.
2. On the line **immediately above** it, add:
   `<!-- CI rewrites the base href below to the Pages base path; see .github/workflows/deploy-pages.yml -->`.
   Don't put the literal tag text in the comment, or the `sed`/`grep -c` would match twice.
3. **Immediately after** the `<base href="/" />` line (so before the stylesheet links, the import
   map, and `blazor.webassembly.js`), add the decoder:

```html
<script>
  // Counterpart to 404.html (GitHub Pages SPA fallback): turn /workflow-engine/?/workflow/abc&x=1
  // back into /workflow-engine/workflow/abc?x=1 before the Blazor router reads the URL.
  // No-op unless the query string starts with "?/", so local dev is unaffected.
  (function (l) {
    if (l.search[1] === '/') {
      var decoded = l.search.slice(1).split('&').map(function (s) {
        return s.replace(/~and~/g, '&');
      }).join('?');
      window.history.replaceState(null, null, l.pathname.slice(0, -1) + decoded + l.hash);
    }
  }(window.location));
</script>
```

### Step 4: Add `.github/workflows/deploy-pages.yml`

```yaml
name: Deploy web app to GitHub Pages

on:
  push:
    branches: [main]
    paths:
      - 'web/**'
      - '.github/workflows/deploy-pages.yml'
  workflow_dispatch:

# Least privilege for the Pages deploy: read the repo, write Pages, mint the OIDC token
# deploy-pages uses to authenticate the deployment.
permissions:
  contents: read
  pages: write
  id-token: write

# One deploy at a time; don't cancel an in-flight production deploy mid-way.
concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-dotnet@v6
        with:
          dotnet-version: '10.0.x'

      - id: pages
        uses: actions/configure-pages@v6

      - name: Publish Blazor WASM
        run: dotnet publish web/WorkflowApp.Web.csproj -c Release -o publish

      - name: Set <base href> for the Pages base path
        env:
          BASE_PATH: ${{ steps.pages.outputs.base_path }}
        run: |
          f=publish/wwwroot/index.html
          sed -i "s|<base href=\"/\" />|<base href=\"${BASE_PATH}/\" />|" "$f"
          # Fail loudly rather than deploy a white screen if the tag format ever drifts.
          test "$(grep -c "<base href=\"${BASE_PATH}/\" />" "$f")" -eq 1
          grep -n '<base href' "$f"

      - uses: actions/upload-pages-artifact@v5
        with:
          path: publish/wwwroot

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v5
```

Notes:

- The `paths:` filter means commits that touch only `supabase/`, `plans/`, or `PROGRESS.md`
  don't redeploy. Use `workflow_dispatch` for manual runs.
- If `base_path` is empty, the rewrite is a no-op that produces `<base href="/" />`, and the
  assertion still passes.
- `configure-pages` runs without `enablement: true`, because `GITHUB_TOKEN` can't enable Pages.
  Enabling Pages is Step 5.

### Step 5: Enable Pages (one-time repo setting; needs user approval)

- Go to **Settings → Pages → Build and deployment → Source** and choose **"GitHub Actions"**.
  The CLI equivalent is
  `gh api -X POST repos/datasciguycode/workflow-engine/pages -f build_type=workflow`. The
  implementer may run that command only with the user's explicit OK.
- Until Pages is enabled, `configure-pages` and `deploy-pages` fail with "Not Found".
- The auto-created `github-pages` environment allows deploys only from the default branch. That's
  the desired behavior.

### Step 6: Supabase Auth URL configuration (user, in the dashboard; **sign-in breaks if skipped**)

In the Supabase dashboard, open project `workflow-engine-test` → **Authentication → URL
Configuration**:

- **Redirect URLs:** add the exact URL `https://datasciguycode.github.io/workflow-engine/`.
  - Don't use a `**` wildcard. The URL is permanent, the implicit flow always returns to the bare
    base URI, and Supabase recommends exact entries for production.
  - Keep the existing localhost entries.
- **Site URL:** this is GoTrue's fallback when `redirect_to` isn't allow-listed. Recommendation:
  set it to the Pages URL. Local dev still works, because dev sends its own allow-listed
  localhost `redirect_to`. If Site URL stays on localhost, a typo in the allow-list silently
  sends Pages users to localhost after Google sign-in. This is the user's call.
- **Google Cloud Console:** expected to need no change. Google redirects to the Supabase
  callback, which is already registered, not to the app. The user should confirm.
- **`supabase/config.toml`:** don't edit it. Its `[auth]` URLs only affect the local stack.

### Step 7: Local pre-flight before pushing

```bash
S=<scratch>
dotnet publish web/WorkflowApp.Web.csproj -c Release -o "$S/publish"
sed -i 's|<base href="/" />|<base href="/workflow-engine/" />|' "$S/publish/wwwroot/index.html"
grep -c '<base href="/workflow-engine/" />' "$S/publish/wwwroot/index.html"   # expect 1
mkdir -p "$S/site" && cp -r "$S/publish/wwwroot" "$S/site/workflow-engine"
python3 -m http.server -d "$S/site" 8080
```

1. Load `http://localhost:8080/workflow-engine/` and check three things:
   - The app boots.
   - The network tab shows no 404s for `_framework`, `_content`, or `css`.
   - Opening a workflow and using the back link keeps the URL under `/workflow-engine/`.
2. Load `http://localhost:8080/workflow-engine/?/workflow/<real-id>`. The decoder should rewrite
   the URL to `/workflow-engine/workflow/<real-id>` and render the detail page.
   - `http.server` doesn't serve `404.html` for misses, so the redirect half of the fallback can
     only be tested live.

Sign-in won't work from `localhost:8080`, because it isn't allow-listed. That's expected; auth
is tested live.

### Step 8: Commit, push, verify live

1. Make two commits: (a) the subpath fixes in app code (Step 1); (b) the Pages deploy (Steps 2–4).
2. Push to `main`, then run `gh run watch`.
3. Live checks on `https://datasciguycode.github.io/workflow-engine/`:
   1. The app boots.
   2. Google sign-in returns to the Pages URL, signed in.
   3. Opening a workflow gives the URL `/workflow-engine/workflow/<id>`.
   4. Hard-refreshing that URL bounces through `404.html` and lands on the same workflow, still
      signed in.
   5. Pasting the deep link into a fresh tab gives the same result.
   6. A chat/agent-loop call succeeds from the new origin.
   7. `/workflow-engine/nope` renders the Blazor `NotFound` page, not GitHub's 404.

### Step 9: Final report to the user (must include all of these)

- The live URL, and the result of each live check above.
- Manual steps: whether Step 5 (enable Pages) was done and by whom, and that Step 6 (Supabase
  Redirect URL, plus the Site URL decision) is required. Say whether the user has confirmed doing
  it.
- **Service-worker flag:**
  - The csproj declares
    `<ServiceWorker Include="wwwroot\service-worker.js" PublishedContent="wwwroot\service-worker.published.js" />`,
    but neither file exists, so publish emits no service worker.
  - The `index.html` comment claiming "service-worker.js itself is untouched" is false.
  - Re-enabling registration would 404.
  - Not fixed here.
- **Cache caveat:** for up to about 10 minutes after a deploy, a browser may hold an old
  `index.html` that points at deleted fingerprinted files. A hard reload fixes it.
- Don't update `PROGRESS.md` as part of this plan. Per `CLAUDE.md`, that happens only when the
  user asks for a milestone.

## Assumptions (still unverified)

- `ubuntu-latest` x64 with `setup-dotnet 10.0.x` publishes without `wasm-tools`, as linux-arm64
  did locally. The first CI run confirms this.
- The current Supabase cloud Site URL and Redirect URL values can't be seen from the repo. Step 6
  assumes the Pages URL isn't allow-listed yet.

## Risks and edge cases

- **Stale `index.html` during the CDN cache window.** Pages sends `Cache-Control: max-age=600`,
  and the `<meta http-equiv>` no-cache tags don't override that. An old `index.html` can request
  fingerprinted files the new deploy removed. A hard reload fixes it; a real fix is out of scope.
- **The `<base>` rewrite depends on tag formatting.** The CI assertion catches drift.
- **`pathSegmentsToKeep = 1` is tied to the project-page URL.** It must change to `0` on a custom
  domain; a comment in the file says so. It isn't derived automatically.
- **Every 404 on the site goes through the redirect, not just route misses.** A typo'd asset path
  in `<img>`/`<script>` gets redirected into `index.html?/…` instead of failing as a clean 404, so
  it shows up as a confusing decode or MIME error. When debugging an odd asset failure, look for
  `?/` in the request URL.
- **Query strings containing `~and~`** are mis-decoded. This is theoretical; the app uses no query
  strings.
- **Public artifact.** The Supabase URL and publishable key are already in this public repo, and
  RLS enforces access. Nothing new is exposed.
- **Rollback:**
  - Fastest: re-run an earlier successful run with `gh run rerun <run-id>` or "Re-run all jobs" in
    the Actions UI. Don't use `workflow_dispatch` for this: it takes a branch or tag, not a SHA.
  - Alternatively, revert the commit and push.
  - To take the site down entirely: Settings → Pages → Unpublish, or delete the workflow.
  - Step 1's code changes are safe on their own at `/`.

## Out of scope

- A custom domain or `CNAME`.
- Restoring the service worker or PWA support, and removing the dev no-cache meta tags.
- Moving `SupabaseConfig` into per-environment config.
- PR preview deploys.
- CI for `supabase/` or the `scripts/` Python tests.
- The `wasm-tools`, AOT, relinking, or Brotli delivery.
- Performing the Supabase or Google console changes. Those are the user's steps.

---

## Adjudication notes

### Architectural fit

The plan fits the codebase. It adds no new runtime pattern:

- Config stays hardcoded and absolute.
- The app-code changes are three link and CSS fixes that are correct at any base path.
- The deploy is the stock GitHub and Microsoft pattern.
- The only new coupling is between `404.html` and the decoder, and between the `<base>` tag text
  and the CI `sed`. Both are documented in comments, and the second is enforced by an assertion.

There's also a fix to the draft's rollback step: `workflow_dispatch` can't target an old SHA, so
rollback now uses `gh run rerun`.

### Plan-reviewer findings (structure)

1. **The `PROGRESS.md` bullet inside Step 8 contradicts itself.** Valid. It moved to Step 9 as an
   explicit "don't do this here."
2. **A verified fact sits under "Assumptions".** Valid. The `configure-pages` `base_path` fact
   moved to Grounding.
3. **D2 left an "if reviewers prefer minimalism" hedge.** Valid. Decided: the rafgraph redirect
   stays, and the copy-`index.html` option is marked rejected. The task asked for the redirect
   trick, and it returns 200 for deep links.
4. **Step 7 didn't give the literal `sed`.** Valid. The exact commands are now given, with the
   assertion and the order of operations.
5. **Obligations to tell the user were split across sections.** Valid. They're consolidated into
   Step 9's checklist: manual steps, the service-worker flag, and the cache caveat.
6. **The decoder's placement was vague.** Valid. It's now anchored "immediately after
   `<base href>`", and the CI comment goes immediately above it.

### Sanity-check findings (substance)

1. **Add `.nojekyll` as a zero-cost hedge.** **Invalid as proposed.**
   - Settled by reading `upload-pages-artifact@v5.0.0`'s `action.yml`: it tars with
     `--exclude=.[^/]*` unless `include-hidden-files: true`, so the proposed `touch` would be
     silently dropped. The hedge isn't zero-cost; making it work needs a second change.
   - On the substance, Jekyll doesn't run for Actions-sourced Pages. Microsoft's own reference
     `static.yml`, with the same action versions and no `.nojekyll`, serves `_framework/` fine.
     The prose doc the sanity check cited is stale.
   - Not adopted. If `_framework` ever 404s on the first deploy, the fix is
     `web/wwwroot/.nojekyll` **plus** `include-hidden-files: true`. That's a one-line fallback,
     and live check 1 would surface the problem immediately.
2. **`FluentLink` renders `<fluent-link>`, not a plain `<a>`.** Valid correction; the conclusion
   is unchanged. The wording is fixed in Grounding, and the bad assumption is removed.
3. **The "Pages compresses on the fly" wording is imprecise.** Valid. D4 now gives the accurate
   mechanism: nothing requests the sidecars. The decision is unchanged.
4. **The 404 redirect also catches asset 404s.** Valid. Added to Risks.
5. **Prefer an exact Supabase redirect URL over a wildcard.** Valid and adopted. The exact URL is
   the only one Step 6 gives. I also made a recommendation on Site URL instead of leaving it
   open.
6. **Microsoft's doc uses `ghaction-rewrite-base-href`.** Considered and not adopted, as the
   sanity check itself recommended. Recorded under D1's rejected alternatives.
