# Progress

- Status (2026-11-09): dev is live and working — Blazor WASM app on GitHub Pages
  (`https://datasciguycode.github.io/workflow-engine/`), backed by Supabase (cloud project
  `workflow-engine-test`, ref `utwyvtbzesswpoihmlic`). Google OAuth sign-in works end to end.
- **Dev brought to parity with prod (2026-11-09)**, now that the tester moved to prod and
  dev was safe to redeploy. Ported from `workflow-app-prod` (preserving dev's own
  `SupabaseConfig`/branding): the agent-grounding fix (item_id optional on
  move_stage/update_data/add_note, resolved server-side to the job open in the UI; forceful
  system-prompt reminder with job number; other-jobs queue withheld while a job is open),
  stable "Job #N" numbering, per-job Claude conversation scoping, job-level vs. stage-level
  notes (with their own Notes sections, positioned below the chat box/buttons so a growing
  notes list no longer pushes the input down), the 5-message add_note nudge, an
  `agent_events` table logging per-call token usage/errors, "Other Appointments" on the
  Scheduling stage, and tap-to-search on the Jobs list (`search_items` RPC — matches job
  data values, stage title, and job number; no live-as-you-type, no full-list client load).
  Also ported two session-origin-collision fixes (dev and prod Pages share the
  `datasciguycode.github.io` origin): `AuthState`'s localStorage key and `index.html`'s
  build-check sessionStorage flag are now both scoped per Supabase project/baseURI so
  visiting one site doesn't clobber the other's session or re-check state.
  4 migrations applied (`20261108000000_add_agent_events.sql`,
  `20261108010000_add_note_who_to_chat_messages.sql`,
  `20261108020000_add_note_explicit_stage_id.sql`, `20261108030000_add_search_items.sql`),
  `agent-loop` edge function redeployed, web app committed and pushed.
- **Production** is a separate repo + Supabase project: `datasciguycode/workflow-engine-prod`,
  live at `https://datasciguycode.github.io/workflow-engine-prod/`, Supabase project
  `workflow-engine-prod` (ref `tapguiosrjbdusqyhxqe`), account "Falcon Auto and Performance."
  Full plan/history: `plans/prod-instance-setup/final-plan.md` in this repo. Prod's own
  `PROGRESS.md` (in `/home/mmcbride/micah/claude/workflow-app-prod`) has its current status.
- **Default-privileges fix** already applied directly to both projects' databases (infra, no
  commit needed): `alter default privileges in schema public revoke all on tables from anon,
  authenticated;` — future tables in either project now start locked down by default.
- **Planned, not started: scope the Jobs-page chat to the job actually open.** Dev's chat box
  is still visible on the bare Jobs list even before "+ New Job" is clicked, and the queue
  sent with every request still lists every job regardless of whether one is already open —
  the agent-grounding fix above makes mistargeting server-side-safe even so, but the queue
  itself hasn't been scoped down the way prod's was.
- **Deferred follow-ups** (full detail in `plans/prod-instance-setup/final-plan.md` →
  "Out of scope (deliberate)"): an admin UI for accounts/members, photo-to-field extraction
  (e.g. VIN from a photo), an upcoming-appointments list on the intake screen (separate from
  the Scheduling-stage one already built), making the prod repo private (needs GitHub Pro),
  an Anthropic spend alert (Console-side, not code), and job assignment/claiming (including
  at intake time) for multiple workers sharing one account's job queue.
- Outstanding: nothing uncommitted in either repo once this commit lands. Both dev and prod
  fully committed, pushed, live, and at feature parity.
