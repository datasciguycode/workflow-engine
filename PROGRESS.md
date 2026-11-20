# Progress

- **Dev** is live and working — Blazor WASM app on GitHub Pages
  (`https://datasciguycode.github.io/workflow-engine/`), backed by Supabase (cloud project
  `workflow-engine-test`, ref `utwyvtbzesswpoihmlic`). Google OAuth sign-in works end to end.
- **Production** is a separate repo + Supabase project: `datasciguycode/workflow-engine-prod`,
  live at `https://datasciguycode.github.io/workflow-engine-prod/`, Supabase project
  `workflow-engine-prod` (ref `tapguiosrjbdusqyhxqe`), account "Falcon Auto and Performance."
  Full plan/history: `plans/prod-instance-setup/final-plan.md`. Prod's own `PROGRESS.md` (in
  `/home/mmcbride/micah/claude/workflow-app-prod`) has its current status.
- **Default-privileges fix** already applied directly to both projects' databases (infra, no
  commit needed): `alter default privileges in schema public revoke all on tables from anon,
  authenticated;` — future tables in either project start locked down by default.

## Dev-only features not yet ported to prod

Prod is behind dev. None of these have been ported:
- Per-stage optional checklist fields (`stages.optional_checklist`).
- Hide-closed-jobs toggle on the Jobs list.
- VIN photo scanner (`scan-vin` edge function).
- Nutrition Tracker workflow (5 sequential meal stages) + scan-plate food-photo estimator.
- **Generic per-workflow Report (2026-11-16)**: `workflows.report_config` (nullable jsonb,
  same precedent as `checklist`) drives one generic `report_series` RPC and one generic
  `WorkflowReport.razor` page — no per-workflow code. Nutrition Tracker's config shows four
  weekly-average cards (Calories, Protein, Carbs, Fat) with a one-period stepper. Calories is
  derived (Atwater weights over protein/carbs/fat) and never stored. `item_requires` drops a
  day from every reported field, not just one, when it's missing any macro. Full design/
  decision trail: `plans/generic-report-feature/final-plan.md`. Verified on dev: migrations
  applied, local + dev write-path checks pass (`scripts/report_series_dev_check.sql`), mechanic
  dry run confirms the engine generalizes (`scripts/report_mechanic_dry_run.sql`), live phone
  checks on the deployed page match the database exactly.
- **`move_stage` backward-move fix (2026-11-17, `20261116000000`)**: every sequenced move
  (forward or backward) now saves the departing stage's shared-field values and restores the
  arriving stage's own latest snapshot, so `item.data` always holds the current stage's real
  value or nothing. Fixes the residual limitation left by the Report feature's forward-only
  snapshotting. User accepted the one visible behavior change (going back to a stage now shows
  that stage's own earlier values, not whatever's currently in `item.data`). Depends on
  `20261113000000` and `20261115000000`. Full design/decision trail:
  `plans/move-stage-backward-snapshot/final-plan.md`. Verified on dev: defect reproduced against
  the pre-fix function, fix confirmed, `scripts/report_series_dev_check.sql` and the new
  `scripts/move_stage_backward_dev_check.sql` both pass post-push, real Nutrition Tracker report
  output unchanged.

`plans/diet-workflow/test-plate.jpg` is intentionally **not** committed (personal photo, public
repo).

## In progress: Rideshare Mileage/Expenses workflows

Vetted plan (plan-pipeline, approved-with-changes): `plans/uber-mileage-tracker/final-plan.md`.
Two dev-only workflows for Uber/Lyft drivers — "Rideshare Mileage" (shift-level odometer-photo
scan at Start/End, derived miles/hours, optional tolls/parking/earnings) and "Rideshare Expenses"
(flat category/amount/date log) — plus four generic report-engine extensions (signed derived
weights, hidden fields, timestamp parsing, item_date_key) that the Mileage workflow needs. GPS/
reverse-geocoding was dropped in favor of plain manual address text fields after further
discussion with the user; no third-party geocoding service is used anywhere in this feature.

**Done:** Steps 1–4. Both migrations (`20261120000000` engine extensions,
`20261120010000_add_rideshare_workflows.sql`) are applied to dev. `scripts/report_series_dev_check.sql`
(37 reject cases + 2 accept cases) and the new `scripts/rideshare_report_dev_check.sql` (two-shift
week miles/hours, in-progress shift, malformed `end_time`, expense date bucketing) both PASS.
Nutrition Tracker's report output is byte-identical before/after. The two Rideshare workflows and
their report configs now exist on dev; no UI/edge-function work has happened yet.

**Next concrete step:** Step 5 — edge functions: `scan-odometer` (copied from `scan-plate`'s
one-shot vision pattern) and the generic `agent-loop` change so the chat agent knows today's date
(needed for expenses logged by relative date, e.g. "$42.10 gas yesterday"). Then Step 6 (web
changes: odometer capture block, `_usd`/date-only field rendering, the Jobs-list "closed" rule
change, display-name disambiguation for same-day items). Full spec in
`plans/uber-mileage-tracker/final-plan.md`.

## Outstanding

- Decide whether/when to port dev's accumulated features (listed above) to prod.
- `closed_at` migration (`20261119000000`, committed to dev's repo) still needs to be applied to
  prod's live DB and to prod's `bootstrap.sql`/`create_test_account.sql` — tracked in this
  session's memory as a to-do, not yet resumed.
