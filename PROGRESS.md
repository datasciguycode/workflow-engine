# Progress

- Status (2026-11-03): backend (Phases 0–4b) and the Blazor WASM UI are both built and
  working, with Google OAuth + the chat/agent-loop path verified live against cloud
  Supabase. GitHub Pages deploy is built and committed but **not yet live** — see below.
- This session: ran the new plan-pipeline skill (`.claude/skills/plan-pipeline/`, agents in
  `.claude/agents/`) end to end for the first time, producing
  `plans/github-pages-deploy/final-plan.md`, then implemented it:
  - Fixed 3 absolute-path bugs (`Home.razor`, `WorkflowDetail.razor`, `app.css`) that would
    break once the app is served from a subpath instead of `/`.
  - Added `.github/workflows/deploy-pages.yml` (build + deploy to Pages, rewrites
    `<base href>` in CI to the Pages base path), `web/wwwroot/404.html` + a decoder in
    `index.html` (rafgraph SPA-redirect trick, so deep links survive a hard refresh).
  - Enabled GitHub Pages on the repo (Source: GitHub Actions) via `gh api`. Target URL:
    `https://datasciguycode.github.io/workflow-engine/`.
  - User added the Pages URL to Supabase Auth → Redirect URLs and updated Site URL to match.
- **Blocked / not yet live:** `git push` is rejected — `refusing to allow an OAuth App to
  create or update workflow .github/workflows/deploy-pages.yml without workflow scope`. The
  local `gh` token only has `gist`, `read:org`, `repo`. User needs to run
  `gh auth refresh -h github.com -s workflow` to add it, but is currently stuck mid-flow: a
  GitHub account-verification code (2FA or new-device check) isn't arriving by SMS/email.
  Troubleshooting suggested (check spam, check for an authenticator-app code instead,
  check githubstatus.com) but unresolved as of this milestone.
- Next step once unblocked: `git push origin main` (6 commits ahead — the Pages deploy work
  plus the plan-pipeline skill/plan trail), then verify the live site per
  `plans/github-pages-deploy/final-plan.md` Step 8's checklist (app boots, sign-in
  round-trips, deep-link refresh works, `/nope` renders Blazor's NotFound not GitHub's 404).
- Outstanding: nothing uncommitted. All 6 unpushed commits are real, finished work — not
  held back intentionally, just blocked on the GitHub auth scope issue above.
