# Sanity check: GitHub Pages deploy plan (round 1)

Method: read the plan against the actual repo (`web/`, `supabase/functions/agent-loop`,
`supabase/config.toml`), ran a real `dotnet publish web/WorkflowApp.Web.csproj -c Release`
locally and inspected the output byte-for-byte, replayed the CI `sed`/`grep` assertion against
that real output, pulled `FluentLink`'s actual source from `microsoft/fluentui-blazor`, and
cross-checked the design against Microsoft's current (2025-11-11, `aspnetcore-10.0`) official
"Host and deploy Blazor WebAssembly with GitHub Pages" doc and its reference `static.yml`
workflow (`dotnet/blazor-samples`). Overall: this is an unusually well-researched plan — most of
the adversarial angles I went looking for had already been checked and closed out in the plan
itself (D1–D4's "Rejected" sub-bullets, the subpath bug audit). I did not find a defect severe
enough to block implementation. The findings below are refinements, not showstoppers.

## Worth considering (no blocker found)

### 1. `.nojekyll` — the plan's reasoning and Microsoft's own prose docs disagree; the cheap hedge costs nothing
**Category:** critique (the stated justification is incomplete, though the conclusion is probably still right)

D4 says `.nojekyll` is unnecessary because "Jekyll never runs" under Source = GitHub Actions, so
`_framework/`/`_content/` (underscore-prefixed) won't be stripped. That's very likely correct —
I fetched Microsoft's own current reference implementation,
[`dotnet/blazor-samples/.github/workflows/static.yml`](https://github.com/dotnet/blazor-samples/blob/main/.github/workflows/static.yml),
and it uses the exact same `configure-pages`/`upload-pages-artifact`/`deploy-pages` pipeline
(same action versions: v6.0.0/v5.0.0/v5.0.1) and does **not** add or reference `.nojekyll`
anywhere in the workflow.

However, Microsoft's prose doc for this same scenario
([Host and deploy Blazor WebAssembly with GitHub Pages](https://learn.microsoft.com/en-us/aspnet/core/blazor/host-and-deploy/webassembly/github-pages))
still says: "The default GitHub Action, which deploys pages, skips deployment of folders
starting with underscore... To deploy folders starting with underscore, add an empty
`.nojekyll` file," pointing at an example file sitting in the *source repo* (outside
`wwwroot`, so it never actually lands in the published artifact — which is itself suspicious,
suggesting the doc prose is stale relative to the actual `static.yml`). The two sources
disagree, and I could not fully resolve which is authoritative for the serving layer (vs. just
the Jekyll build step) from documentation alone.

**Fix:** add an empty `wwwroot/.nojekyll` to the publish output in Step 4's workflow (one extra
`touch publish/wwwroot/.nojekyll` line, or ship the file in `web/wwwroot/` directly so it's
part of every publish). It is strictly zero-cost and removes a documented class of failure
(silently-missing `_framework/`) entirely, regardless of which account of GH Pages' serving
layer is right.

### 2. The `FluentLink` "plain `<a href>`" assumption is factually wrong, though the conclusion it draws from it still holds
**Category:** critique

The plan's "Assumptions (unverified)" section says: "The FluentUI v5 `FluentLink` renders `Href`
as a plain `<a href>`, which is what makes `./` resolve against `<base>`." I pulled the actual
source (`microsoft/fluentui-blazor`, `src/Core/Components/Link/FluentLink.razor`):

```razor
<fluent-link href="@Href" ... clickable="@OnClick.HasDelegate" force-load="@(ForceLoad ? "true" : null)" @onclick="@OnClickHandlerAsync" ...>
```

It renders a custom element (`<fluent-link>`), not a plain `<a>`. That said, the plan's
*conclusion* still holds, for reasons the plan didn't have in hand: (a) relative URL resolution
(`./`) is a document-wide property (the `<base>` tag), not scoped by shadow DOM, so `href="./"`
still resolves against `<base href>` regardless of the wrapping element; and (b) the
`.razor.cs` doc comment on `ForceLoad` states "Default is `false`, which uses Blazor's
built-in navigation" — i.e., the library's own authors designed `fluent-link` to integrate with
Blazor's click-interception/SPA routing by default, which is exactly what `WorkflowDetail.razor`
relies on (it never sets `ForceLoad`).

**Fix:** none required — correct the assumption's wording for future readers ("renders a
`<fluent-link>` custom element with an internal anchor; href resolution and Blazor-navigation
interception both still work, per the component's own `ForceLoad` contract") rather than leaving
a now-known-false "plain `<a>`" claim in the decisions doc. Step 8's live check (open a workflow,
use the back link) will catch it either way if this reasoning is somehow wrong in practice.

### 3. D4's "GitHub Pages compresses on the fly" reasoning for the `.br`/`.gz` sidecars is imprecise, but the decision to leave them is still correct
**Category:** critique (reasoning) / alternative (named, but not recommended)

Microsoft's own doc is explicit: "GitHub Pages doesn't natively support using
Brotli-compressed resources," and the *only* way to actually use the `.br` files on Pages is an
opt-in mechanism (a custom `wwwroot/decode.js`, `autostart="false"` on the Blazor script tag,
plus a `loadBootResource` override) — not automatic negotiation. So "GitHub Pages compresses on
the fly" isn't really what's happening; what's actually happening is simpler and better for this
plan's purposes: the import map and `<script src>` references point at the **uncompressed**
`_framework/*.js`/`*.wasm` files (verified directly in the local publish output), so the `.br`/
`.gz` siblings are just inert dead weight that nothing ever requests. The practical conclusion —
leave them, don't bother wiring up Brotli delivery for a single-user internal app — is sound;
only the stated mechanism is off.

**Fix:** none required to the plan's steps; optionally tighten the D4 wording from "Pages
compresses on the fly" to "nothing on the page ever requests the `.br`/`.gz` files, so they're
simply unused bytes in the artifact."

### 4. The rafgraph/404 technique bounces *every* 404 through `index.html`, not just router-level ones — a known, inherent cost of the chosen pattern, worth naming explicitly in Risks
**Category:** critique

GitHub Pages' custom 404 applies to any unmatched path under the project's namespace —
including a stray `<img src>`/`<script src>` typo, not just SPA route misses. Such a request
gets silently redirected into `index.html?/...` rather than surfacing a clean 404 in the network
tab, which makes a genuine broken-asset-reference bug ship-time harder to spot (it still fails —
the browser can't decode `index.html` as an image/script — but the failure mode is more
confusing to diagnose than a normal 404). This is an accepted, well-known tradeoff of the
rafgraph/rafrex pattern (and the Microsoft doc uses the same pattern with the same tradeoff), not
a defect in this plan's execution of it.

**Fix:** none required; add one sentence to the "Risks and edge cases" section naming this so a
future "why did this asset load weirdly" investigation isn't a surprise.

### 5. Supabase's own docs recommend an exact redirect URL over a wildcard for production; Step 6 presents both without a preference
**Category:** alternative (named, minor)

[Supabase's Redirect URLs docs](https://supabase.com/docs/guides/auth/redirect-urls) confirm the
plan's allow-list/Site-URL-fallback mechanics exactly as described, and confirm wildcards
(`**`) are supported — but explicitly recommend exact redirect paths for production, reserving
`**` for preview/ephemeral URLs (Netlify/Vercel-style). Step 6 offers
`https://datasciguycode.github.io/workflow-engine/` or the `**` variant as equally valid; since
this URL is permanent (a GitHub Pages project URL doesn't change), the exact entry is strictly
preferable here and the wildcard adds no value.

**Fix:** state the exact URL as the one to add, drop the wildcard option (or mark it explicitly
as "only if deep-linking with query strings turns out to need it," which it shouldn't given the
implicit-flow redirect always lands on the bare base URI).

### 6. Named alternative to D1, for completeness: Microsoft's own doc uses a third-party action (`SteveSandersonMS/ghaction-rewrite-base-href`, SHA-pinned) instead of a hand-rolled `sed`
**Category:** alternative (named; not recommending the switch)

Flagging this because my brief was to name concrete alternatives, not because I think the plan
should change: Microsoft's reference workflow rewrites `<base>` via a third-party action, which
it insists on SHA-pinning (not even a version tag) specifically because it's an individual's
action outside the `actions/` org, and that requires an extra one-time repo setting
("Allow actions and reusable workflows" allow-listing). The plan's hand-rolled `sed` + `grep -c`
assertion achieves the identical result with one fewer third-party trust dependency and no extra
repo-settings step. I'd keep the plan's approach as-is; it's arguably better than the one
Microsoft's own doc uses, not worse.

## What held up under adversarial checking (stated for completeness, not as findings)

- Ran `dotnet publish` for real: it succeeds without `wasm-tools` (warning only, as claimed),
  and the output's `<base href="/" />`, import map, and all internal asset references are
  exactly as the plan describes — confirmed by grepping the *entire* publish output for any
  remaining absolute-rooted reference (`"/_`, `href="/`, `src="/`): the only two hits were the
  two the plan already found and fixes (`index.html`'s `<base>` and `app.css`'s `@import`).
  No missed subpath bug in FluentUI's own shipped JS/CSS.
- Replayed the CI `sed`/`grep -c` assertion against the real publish output with
  `BASE_PATH=/workflow-engine`: passes, produces `<base href="/workflow-engine/" />`.
  No interaction with the import map or fingerprinting (verified the import map uses `./`-
  relative keys, unaffected by the base-href swap).
  CORS: verified `agent-loop/index.ts` sends `Access-Control-Allow-Origin: *` exactly as the plan
  states, so Step 6's "no CORS change needed" is correct.
  `StripFragment()`/`SignInWithGoogle()`/`AuthState` base-URI handling: traced through the
  actual code; the plan's description of the implicit-flow fragment handling and `BaseUri` usage
  is accurate.
- Action versions/outputs (`configure-pages@v6` → `base_path`, `upload-pages-artifact@v5`,
  `deploy-pages@v5`) and the overall two-job artifact-based workflow shape match Microsoft's own
  current reference `static.yml` almost line for line (same action versions, same permissions
  block, same concurrency group, same trigger shape).

## Summary

- Findings: 6, all in the "worth considering" bucket — 4 critique, 2 named-alternative, 0
  cut-this.
- Nothing rises to "must address before implementation." The one item closest to a real risk
  (`.nojekyll`) is genuinely ambiguous in the docs rather than clearly wrong in the plan, and the
  fix is a zero-cost hedge either way.
- Does not block the plan as written.
