# Progress

- Status (2026-11-07): dev is live and working, same as before — Blazor WASM app on GitHub
  Pages (`https://datasciguycode.github.io/workflow-engine/`), backed by Supabase (cloud
  project `workflow-engine-test`, ref `utwyvtbzesswpoihmlic`). Google OAuth sign-in works
  end to end.
- **Production now exists, as a separate repo + separate Supabase project.** Stood up this
  session via the plan-pipeline skill (`plans/prod-instance-setup/final-plan.md`, 3 draft
  rounds + architect sign-off), executed against a sibling clone at
  `/home/mmcbride/micah/claude/workflow-app-prod`:
  - Repo: `datasciguycode/workflow-engine-prod` (public — GitHub Pages needs a paid plan to
    serve from private, deferred for later).
  - Live at `https://datasciguycode.github.io/workflow-engine-prod/`.
  - Supabase project `workflow-engine-prod` (ref `tapguiosrjbdusqyhxqe`), same org as dev
    (`swdeqnlbogugszsnyqlr`), free tier, with a keep-alive GitHub Actions workflow
    (`.github/workflows/keep-alive.yml` in the prod repo) pinging it every 3 days so it
    doesn't auto-pause, and self-committing a timestamp so the workflow itself doesn't get
    disabled by GitHub's own 60-day scheduled-workflow cutoff.
  - Account: "Falcon Auto and Performance" (copy of dev's "Joe's Auto Repair" stage
    structure, renamed), owner `fly.data.sci.guy@gmail.com`. Fully verified live: sign-in,
    deep-link refresh, agent chat (create job + Complete Stage), and isolation (anon
    requests get a hard permission-denied, not just empty rows).
  - Found and fixed during setup: a fresh Supabase project grants `anon`/`authenticated`
    broad default table privileges that dev's schema doesn't have (dev must have had an
    undocumented manual `revoke` at some point — confirmed out-of-band drift). Corrected on
    prod to match dev's exact grant set; not RLS-exploitable either way, but worth knowing
    if this surprises you again on a future project.
  - **This repo's local `supabase/.temp/project-ref` and Docker containers are untouched** —
    confirmed repeatedly during the build. The prod clone has its own `project_id` (set to
    `workflow-app-prod` in its `supabase/config.toml`) specifically so local Supabase
    commands run from that clone can never act on this repo's running containers.
- **Pending push to dev:** a small header CSS fix (`.page-header-chat` centering — the Chat
  button was defaulting to left-alignment within its grid column, reading as the whole
  header being skewed) is committed locally (`a608106`) but **not yet pushed**, since dev
  has an active test session today and pushing deploys immediately. Also still unpushed
  from before: `390fc11` (PROGRESS.md refresh). Push both whenever it's safe to redeploy
  dev.
- **Deferred follow-ups** (full detail in `plans/prod-instance-setup/final-plan.md` →
  "Out of scope (deliberate)"): an admin UI for accounts/members, photo-to-field extraction
  (e.g. VIN from a photo), scheduling visibility (agent tool to see/warn about other jobs'
  `scheduled_at`), an upcoming-appointments list on the intake screen, making the prod repo
  private (needs GitHub Pro), an Anthropic spend alert (Console-side, not code), and job
  assignment/claiming for multiple workers sharing one account's job queue.
- Outstanding: nothing uncommitted in either repo. Dev has 2 commits not yet pushed
  (see above, held back deliberately). Prod is fully committed and pushed.
