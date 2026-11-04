# GitHub Pages deploy for the Blazor WASM app (`web/`): round 1 draft

## Grounding (what's actually there, verified 2026-11-01)

- **Origin:** `https://github.com/datasciguycode/workflow-engine.git`. The repo is **public** and its default branch is `main`. Pages is **not enabled yet** (`gh api repos/datasciguycode/workflow-engine/pages` returns 404). There is no `CNAME` file and no sign of a custom domain anywhere.
  → Target URL: **`https://datasciguycode.github.io/workflow-engine/`**, so the base path is `/workflow-engine/`.
- **No `.github/` directory**, so there is no existing CI.
- **Project:** `web/WorkflowApp.Web.csproj`, `Microsoft.NET.Sdk.BlazorWebAssembly`, `net10.0`, `OverrideHtmlAssetPlaceholders=true` (.NET 10 fingerprinting and import map). The local SDK is 10.0.402. There is no `global.json` and no `.sln`.
- **`web/wwwroot/index.html`** has `<base href="/" />` and loads `_framework/blazor.webassembly#[.{fingerprint}].js`. Every other asset reference is already relative (`css/app.css`, `_content/...`, `manifest.webmanifest`, `js/focus.js`). The service worker registration is commented out.
- **Local publish test** (`dotnet publish web/WorkflowApp.Web.csproj -c Release -o <tmp>`) **succeeds** without the `wasm-tools` workload (it prints a warning only). The output layout is `<out>/wwwroot/{index.html, _framework/, _content/, css/, js/, ...}` plus `.br`/`.gz` siblings, about 20 MB in total. Publishing leaves `<base href="/" />` in the output `index.html` unchanged. A `sed` rewrite to `/workflow-engine/` was tested against that output and works.
- **Runtime config:** `SupabaseConfig` in `web/Services/WorkflowApiClient.cs` hardcodes `ApiUrl = https://utwyvtbzesswpoihmlic.supabase.co` and the publishable key. These are absolute URLs, so they don't depend on the base path. Nothing changes here.
- **OAuth:** `AuthState.SignInWithGoogle()` sends `redirect_to = NavigationManager.BaseUri`, which on Pages will be `https://datasciguycode.github.io/workflow-engine/`. The flow is GoTrue implicit: Google → Supabase `/auth/v1/callback` → `redirect_to#access_token=...`. `StripFragment()` uses `GetLeftPart(Path)`, which keeps the subpath. Both are correct under a subpath.
- **CORS:** the `agent-loop` edge function sends `Access-Control-Allow-Origin: *`, and PostgREST/GoTrue on Supabase cloud allow any origin. The new origin needs no CORS change.
- **Routes:** `@page "/"`, `"/workflow/{WorkflowId}"` and `"/not-found"`. The task's `/items/123` example doesn't exist; the deep-link case that matters here is `/workflow/<uuid>`.

### Subpath bugs found in app code (must fix, or navigation breaks on Pages)

1. `web/Pages/Home.razor:56`: `Nav.NavigateTo($"/workflow/{workflowId}")`. A leading `/` resolves against the **host root**, giving `https://datasciguycode.github.io/workflow/<id>`. That's outside the base URI, so Blazor does a full page load to a URL that isn't this site. Change it to `Nav.NavigateTo($"workflow/{workflowId}")`, which is relative to `<base href>`.
2. `web/Pages/WorkflowDetail.razor:30`: `<FluentLink Href="/" ...>` has the same problem and would leave the app entirely. Change it to `Href=""` or `Href="./"`. `./` resolves against `<base href>` to `/workflow-engine/`. I prefer `"./"` because some components treat an empty `Href` as "no link".
3. `web/wwwroot/css/app.css:1`: `@import url('/_content/Microsoft.FluentUI.AspNetCore.Components/css/reboot.css');` is absolute, so it 404s under the subpath. It's also redundant, because `index.html` already links the same file relatively. **Delete the line.** Don't make it relative: CSS `@import` resolves against the stylesheet's URL, not `<base>`, so it would have to be `../_content/...`, and the duplicate load isn't wanted anyway.

These changes also work at the local dev root (`/`), so there's no dev regression.

## Decisions

### D1. Base href: rewrite it in CI from `configure-pages`' `base_path` output; keep `/` in source

- In source, `index.html` keeps `<base href="/" />`, so `dotnet run` / `dotnet watch` at `localhost:5193/` work unchanged.
- The workflow runs `actions/configure-pages` (id `pages`) and rewrites the published `index.html` to `<base href="${{ steps.pages.outputs.base_path }}/" />`. On a project page, `base_path` is `/workflow-engine`; on a custom domain it would be empty, giving `/`, so this survives a later custom domain without edits.
- A `grep` assertion fails the job if the rewrite didn't match, for example if someone reformats the `<base>` tag. Without it, the site would deploy and white-screen silently.
- **Rejected:**
  - Hardcoding `/workflow-engine/` in source breaks local dev.
  - The MSBuild `StaticWebAssetBasePath` property moves assets into a subfolder of the output; that's a different concern and doesn't set `<base>`.
  - A runtime JS snippet that computes `<base>` from `location.pathname` is clever and fragile, and fights the .NET 10 import-map placeholders.
  - A `sed` hardcoded to `/workflow-engine/` is acceptable, but the `base_path` version is the same effort and also handles a custom domain.
- Editing `index.html` after publish is safe. It isn't covered by Blazor's integrity hashes (the import-map `integrity` entries cover `_framework` JS only). The stale `index.html.br`/`.gz` siblings don't matter because GitHub Pages never serves precompressed sidecars (see D4).

### D2. SPA fallback: the rafgraph `spa-github-pages` redirect pattern

This is the de facto standard for Blazor on GitHub Pages.

- `web/wwwroot/404.html` (published to the site root) rewrites `/workflow-engine/workflow/abc?x=1#h` into `/workflow-engine/?/workflow/abc&x=1#h` with `location.replace`, keeping `pathSegmentsToKeep = 1` segment (the repo name).
- A small decoder `<script>` in `index.html`'s `<head>` turns `?/workflow/abc&x=1` back into `/workflow-engine/workflow/abc?x=1` via `history.replaceState`. It runs **before** `blazor.webassembly.js`, so the Router sees the clean URL on first render.
- The decoder is a no-op unless `location.search` starts with `?/`, so it's inert in local dev and on normal loads.
- **Rejected alternative:** copying `index.html` to `404.html` in CI. It's simpler (one `cp`, no scripts), and Blazor boots fine because `<base>` is absolute. However, every deep-link load returns **HTTP 404**, which some tooling and link previews treat as an error. It also produces a duplicate, divergent copy of `index.html`. The task asked for the standard redirect trick, and the redirect gives a 200. **If reviewers prefer minimalism, this is the fallback.** It's a one-line workflow change, with no `404.html` source file and no decoder.
- Known cost: a deep-link refresh does one extra round trip (404 page → redirect → `index.html`). That's acceptable.
- OAuth isn't affected. Supabase redirects back to the base URI, which exists, so no 404 occurs and the `#access_token=...` fragment stays intact. The redirect script preserves `l.hash` anyway.

### D3. Workflow shape: the official two-job Pages pattern (build → upload artifact → deploy with `actions/deploy-pages`)

- I checked the current releases with `gh api .../releases/latest` on 2026-11-01:
  - `actions/checkout` v7.0.1
  - `actions/setup-dotnet` v6.0.0
  - `actions/configure-pages` v6.0.0
  - `actions/upload-pages-artifact` v5.0.0
  - `actions/deploy-pages` v5.0.1
- I confirmed from each `action.yml` that the inputs used below exist at those tags.
- Use major tags (`@v7`, etc.) rather than SHA pins. SHA pinning is stricter supply-chain hygiene, but it's overkill for a solo public repo. A reviewer may override this.
- **Rejected:** the `peaceiris/actions-gh-pages` / `gh-pages` branch approach. It's legacy, it pollutes history with build output, and it needs `contents: write`. The artifact-based deploy is GitHub's recommended path.

### D4. No `.nojekyll`, no compression tweaks

- With Pages Source = "GitHub Actions", the uploaded artifact is served as-is. **Jekyll never runs**, so `_framework/` and `_content/` aren't stripped, and `.nojekyll` is unnecessary.
- `upload-pages-artifact` v4+ excludes dotfiles by default anyway; v5 has `include-hidden-files` if it's ever needed.
- The `.br`/`.gz` sidecars are inert on Pages, which compresses on the fly. They add about 10 MB to a 1 GB-limit artifact. Leave them. (Optionally pass `-p:CompressionEnabled=false` to speed up the publish; I haven't verified that property name for .NET 10, so it's not in the plan.)

## Implementation steps (in order)

### Step 1: Fix the subpath-unsafe links (app code)

- `web/Pages/Home.razor:56`: `Nav.NavigateTo($"workflow/{workflowId}");`
- `web/Pages/WorkflowDetail.razor:30`: `<FluentLink Href="./" Class="back-link">`
- `web/wwwroot/css/app.css:1`: delete the `@import url('/_content/...reboot.css')` line.
- Verify locally with `dotnet run` at `/`: Home → open a workflow → back link → still works.

### Step 2: Add `web/wwwroot/404.html` (rafgraph, with `pathSegmentsToKeep = 1`)

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

It has to stay comfortably over 512 bytes, or old IE/Edge show their own 404 page. The comment block covers that. (This is a legacy concern noted in the rafgraph README and irrelevant to modern browsers. Keep the comment anyway; it costs nothing.)

### Step 3: Add the decoder to `web/wwwroot/index.html`

Put it in `<head>`, after `<base>` and before any app script:

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

Leave `<base href="/" />` as is, because CI rewrites it (D1). Add a one-line HTML comment next to it: `<!-- CI rewrites this to the Pages base path; see .github/workflows/deploy-pages.yml -->`. Don't put the literal tag text inside the comment, or the `sed` would match twice. The `grep -c` assertion in the workflow checks for exactly one match.

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

Notes on this file:

- `paths:` filtering means commits that only touch `supabase/`, `PROGRESS.md` or `plans/` don't redeploy. `workflow_dispatch` allows manual re-runs.
- If `base_path` is empty (custom domain or user page), the rewrite becomes `<base href="/" />`. In that case the sed is a no-op and the assertion still passes.
- `-o publish` puts the site at `publish/wwwroot`. That matches the layout verified locally.
- `configure-pages` runs **without** `enablement: true`, because `GITHUB_TOKEN` can't enable Pages. See step 5.

### Step 5: One-time repo setting (manual, user)

- In GitHub, go to **Settings → Pages → Build and deployment → Source** and choose **"GitHub Actions"**.
- Until this is set, `configure-pages` and `deploy-pages` fail with "Get Pages site failed / Not Found".
- `gh api -X POST repos/datasciguycode/workflow-engine/pages -f build_type=workflow` does the same thing from the CLI. The implementer can run it if the user approves, since it's a repo settings change.
- The auto-created `github-pages` environment restricts deploys to the default branch by default. That's what we want.

### Step 6: Supabase Auth URL configuration (manual, user; **will break sign-in if skipped**)

- In the Supabase dashboard → project `workflow-engine-test` → **Authentication → URL Configuration**:
  - Add `https://datasciguycode.github.io/workflow-engine/` (or `https://datasciguycode.github.io/workflow-engine/**`) to **Redirect URLs**.
  - Keep the existing localhost entries so local dev still works.
  - Decide whether **Site URL** should become the Pages URL. It's the fallback GoTrue uses when `redirect_to` isn't allow-listed. If it's still localhost, a misconfigured allow-list silently sends you to localhost after Google sign-in.
- **Google Cloud Console: probably no change needed.** In this flow, Google redirects to Supabase (`https://utwyvtbzesswpoihmlic.supabase.co/auth/v1/callback`), not to the app. That callback URI is already registered, since sign-in works today, and "Authorized JavaScript origins" isn't used by a server-side redirect flow. Flagged so the user can confirm. If the OAuth consent screen is in "Testing" mode, only listed test users can sign in from any origin; that's unchanged.
- `supabase/config.toml`'s `[auth] site_url` / `additional_redirect_urls` only affect the **local** Supabase stack. Changing them does nothing for cloud, so don't touch them as part of this work.
- I can't do these steps for the user. The plan's final report must list them explicitly.

### Step 7: Local pre-flight before pushing (implementer)

1. `dotnet publish web/WorkflowApp.Web.csproj -c Release -o <scratch>/publish`.
2. Apply the same `sed`, then stage the output under a subfolder so the subpath matches Pages: `mkdir -p <scratch>/site && cp -r <scratch>/publish/wwwroot <scratch>/site/workflow-engine`.
3. Serve it with `python3 -m http.server -d <scratch>/site 8080`. Load `http://localhost:8080/workflow-engine/` and confirm that the app boots, there are no 404s in the network tab (`_framework`, `_content`, `css`), and navigation into a workflow and back stays under `/workflow-engine/`.
4. Simulate the fallback by hand: load `http://localhost:8080/workflow-engine/?/workflow/<real-id>` and confirm that the decoder rewrites the URL and the detail page renders. `http.server` doesn't serve `404.html`, so the redirect half is tested live.

Sign-in won't work from `localhost:8080`, because it isn't an allow-listed redirect. That's expected; test auth live.

### Step 8: Commit, push, verify live

- Make one commit (or two: app-code subpath fixes, then deploy infra). Push to `main`, then watch with `gh run watch`.
- Live checks on `https://datasciguycode.github.io/workflow-engine/`:
  1. The app boots.
  2. Google sign-in round-trips back to the Pages URL, signed in.
  3. Open a workflow; the URL is `/workflow-engine/workflow/<id>`.
  4. **Hard-refresh that URL.** It redirects through `404.html` and lands on the same workflow, signed in (session from localStorage).
  5. Paste a deep link in a fresh tab and get the same result.
  6. Run a chat/agent-loop call to confirm edge-function CORS from the new origin.
  7. An unknown path such as `/workflow-engine/nope` renders the Blazor `NotFound` page, not GitHub's 404.
- Update `PROGRESS.md` (per CLAUDE.md milestone conventions, only when asked for a milestone): add the live URL and the manual console steps that were done.

## Assumptions (unverified)

- (Verified, not assumed: `configure-pages@v6.0.0`'s `action.yml` declares a `base_path` output, documented as `"/my-repo"` or `""`.)
- `ubuntu-latest` with `setup-dotnet` `10.0.x` can publish without the `wasm-tools` workload, as the local publish on linux-arm64 did. There's no reason it would differ on x64.
- The current Supabase cloud Site URL and Redirect URL values aren't visible from the repo. Step 6 assumes the Pages URL is **not** already allow-listed.
- The FluentUI v5 `FluentLink` renders `Href` as a plain `<a href>`, which is what makes `./` resolve against `<base>`. If it routes through `NavigationManager` itself, `./` still resolves correctly via `ToAbsoluteUri`.

## Risks and edge cases

- **Stale `index.html` during the CDN cache window.** Pages serves everything with `Cache-Control: max-age=600`; the `<meta http-equiv>` no-cache tags in `index.html` don't override HTTP headers on the document itself. For up to 10 minutes after a deploy, a browser may hold an old `index.html` whose fingerprinted `_framework/blazor.webassembly.<oldhash>.js` no longer exists. The artifact deploy replaces the whole site, so old fingerprints are gone and the app fails to boot until reload. For a single-user app, a hard reload is acceptable. A proper fix is out of scope.
- **The `<base>` rewrite is coupled to tag formatting.** It's mitigated by the assertion step. If someone changes it to `<base href="/">` without the self-closing slash, CI fails loudly rather than shipping broken.
- **`pathSegmentsToKeep = 1` is coupled to the project-page URL.** A move to a custom domain needs a change to `0` (commented in the file). Unlike `<base>`, it's not auto-derived. Deriving it would mean templating `404.html` in CI, which isn't worth it now.
- **Query strings containing `~and~`** would be mis-decoded. Theoretical; the app uses no query strings today.
- **Service worker:** the csproj declares `<ServiceWorker Include="wwwroot\service-worker.js" PublishedContent="wwwroot\service-worker.published.js" />`, but **neither file exists in the repo**. Publish silently emits no service worker (verified). Registration is commented out in `index.html`, so nothing breaks. But the comment saying "service-worker.js itself is untouched" is false, and **re-enabling registration for Pages would 404**. Flag it to the user; don't fix it here.
- **Public artifact:** the publishable key and Supabase URL become publicly fetchable from Pages. They're already in this public repo, and publishable keys are designed to be public (RLS enforces access), so nothing new is exposed.
- **Rollback:**
  - Bad deploy: revert the commit and push, or re-run an earlier successful run of the workflow via `workflow_dispatch` on the old SHA.
  - Disable entirely: Settings → Pages → Unpublish, or delete the workflow file.
  - The app-code changes in step 1 are independently safe at `/`.

## Out of scope (explicit)

- A custom domain or `CNAME`.
- Re-enabling or restoring the service worker / PWA offline support, and removing the dev-time no-cache meta tags. That's a separate "production hardening" pass.
- Moving `SupabaseConfig` out of hardcoded constants into `appsettings.json` / per-environment config. It works as is because it's absolute, and there's one environment.
- PR preview deploys (`deploy-pages` `preview: true` is a beta feature with extra requirements).
- Build/test CI for `supabase/` (edge functions, migrations) or running the `scripts/` Python tests in Actions.
- Installing the `wasm-tools` workload for AOT or relinking size optimisation.
- Any changes in the Google Cloud Console or Supabase dashboard. These are documented as manual user steps; the implementer doesn't perform them.
