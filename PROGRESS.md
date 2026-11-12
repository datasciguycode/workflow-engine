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
- **Resolved (was listed as a gap, turned out already fixed by the port):** scoping the
  Jobs-page chat to the job actually open. The wholesale copy of prod's `WorkflowDetail.razor`
  during the 2026-11-09 port brought this along too — the chat box no longer renders at all on
  the bare Jobs list (gated on `_newJobMode || _selectedItem is not null`), and the other-jobs
  reference queue sent with every agent request is now always empty (`queueForThisTurn = new
  JsonArray()`), regardless of what's open.
- **Deferred follow-ups** (full detail in `plans/prod-instance-setup/final-plan.md` →
  "Out of scope (deliberate)"): an admin UI for accounts/members, photo-to-field extraction
  (e.g. VIN from a photo), an upcoming-appointments list on the intake screen (separate from
  the Scheduling-stage one already built), making the prod repo private (needs GitHub Pro),
  an Anthropic spend alert (Console-side, not code), and job assignment/claiming (including
  at intake time) for multiple workers sharing one account's job queue.
- **Dev pulled ahead of prod (2026-11-12)**, several features built in dev only, not yet
  ported to prod:
  - **Per-stage optional checklist fields**: new `optional_checklist` jsonb column on `stages`
    (parallel to `checklist`). `ChecklistLabel` renders a trailing `" *"` on any field not in
    it; `DoneNextStage()` gates on `checklist.Except(optional_checklist)` only. Walked every
    mechanic-workflow stage to pick one required field each (Diagnosis: `diagnosis`;
    Approval: `approved`; In Progress: `technician`; Invoicing: `invoice_number`; Payment
    Receipt Submitted: `receipt_number`; etc. — `parts` on Diagnosis made optional).
  - **Hide closed jobs by default**: Jobs list filters on `stage.IsTerminal` with a "Show
    closed"/"Hide closed" toggle (`VisibleItems()` in `WorkflowDetail.razor`).
  - **VIN photo scanner**: `scan-vin` edge function (one-shot Claude Messages API call, no
    tool loop, photo never stored/added to chat) + a "Scan VIN" button on the Diagnosis stage,
    writing the result via the direct `UpdateDataAsync` RPC wrapper (not through chat).
  - **Nutrition Tracker workflow**: a second workflow on the same engine, same shape as the
    mechanic workflow — a "meal date" item moves through 5 real sequential stages (Breakfast
    → Brunch → Lunch → Linner → Dinner), all checklist fields
    (protein/carbs/fat/fiber/sugar/weight) optional on every stage. Brunch/Linner exist so a
    between-meal snack folds into the nearest stage's running total rather than needing an
    open-ended snack list. No goal-tracking stage (deferred — a workflow can only have one
    `is_initial` stage, already claimed by Breakfast). An earlier, more complex
    all-terminal-peer-stages design went through the full plan-pipeline
    (`plans/diet-workflow/final-plan.md`, `approved-with-changes`) but was superseded by this
    simpler sequential design before implementation, since it maps directly onto patterns the
    engine already supports — the plan directory is kept as historical record only.
  - **scan-plate**: a `scan-vin`-pattern edge function that estimates protein/carbs/fat/fiber/
    sugar grams from a food photo plus an uncertainty note, validated against per-field bounds
    and an Atwater-based implied-calorie plausibility check (10–3000 kcal) before being
    trusted. Verified end-to-end against a real plate photo this session (19g protein / 40g
    carbs / 55g fat / 19g fiber / 11g sugar, sane uncertainty note). Two real bugs found and
    fixed during that test: the `ANTHROPIC_API_KEY` secret had gone invalid (user reset it on
    platform.claude.com) and `max_tokens: 512` was too tight, truncating the JSON response
    mid-string (bumped to 1024). `supabase/config.toml` now has an explicit
    `[functions.scan-plate] verify_jwt = true` — needed because a bare redeploy without
    `--no-verify-jwt` silently no-ops when the function bundle is unchanged, so a test deploy
    with JWT checking off stayed off until an explicit config forced a real redeploy.
  - `plans/diet-workflow/test-plate.jpg` (the real test photo) is intentionally **not**
    committed — personal photo, public repo.
- Outstanding:
  - Dev's web app changes are committed and pushed to `main` (triggers
    `deploy-pages.yml`) — confirm the GitHub Pages deploy succeeds.
  - None of today's dev-only features (optional_checklist, hide-closed-jobs, VIN scanner,
    Nutrition Tracker, scan-plate) have been ported to prod yet — prod is now behind dev,
    mirroring the same kind of gap the 2026-11-09 port closed in the other direction.
  - Next concrete step: decide whether/when to port today's dev features to prod, the same
    way the 2026-11-09 entry above ported prod's features into dev.
