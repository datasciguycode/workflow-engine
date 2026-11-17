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

## Outstanding

- Decide whether/when to port dev's accumulated features (listed above) to prod.
