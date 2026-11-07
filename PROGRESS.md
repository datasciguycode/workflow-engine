# Progress

- Status (2026-11-07): live and working. Blazor WASM app deployed to GitHub Pages
  (`https://datasciguycode.github.io/workflow-engine/`), backed by Supabase (cloud project
  `workflow-engine-test`, ref `utwyvtbzesswpoihmlic`) for data and the `agent-loop` Edge
  Function for chat. Google OAuth sign-in works end to end. User tests primarily via an
  iPhone Home Screen icon (standalone PWA mode).
- Deploy paths (two, separate):
  - App/UI: push to `main` (path-filtered to `web/**`) triggers
    `.github/workflows/deploy-pages.yml` → GitHub Pages.
  - Agent behavior: `supabase functions deploy agent-loop`, run manually from the CLI —
    not triggered by git push.
- Recent UI work (most recent commit `7150837`): job/stage list styling as links with
  arrows, a "Complete Stage" button next to Send for one-tap stage advancement, fixes for
  raw snake_case stage/field names rendering in the UI and in the agent's own chat replies,
  human-readable date/time formatting for date-ish fields, New Job screen no longer leaking
  old chat history, and a build-id-based one-time forced reload to kill recurring
  stale-cache complaints on iOS standalone mode (GitHub Pages' real `cache-control` header
  was overriding the page's own no-cache meta tags).
- Multi-user: added a second account member this session —
  `threadsinc1@gmail.com` as `member` on account `11111111-1111-1111-1111-111111111111`
  ("Acct 1 (isolation test)"), which owns the real "Joe's Auto Repair" workflow/jobs. This
  was done directly via `supabase db query --linked` (no admin UI exists yet for adding
  users — it's a manual two-step: the person signs in once via Google to create their
  `auth.users` row, then an existing account owner inserts their `account_members` row).
- Outstanding: nothing uncommitted; working tree clean. No admin UI for account/member
  management — still requires a direct DB query if more users need to be added.
- Next concrete step: none pending; whatever the user raises next.
