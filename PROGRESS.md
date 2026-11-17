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

`plans/diet-workflow/test-plate.jpg` is intentionally **not** committed (personal photo, public
repo).

## Known limitation (accepted for now, follow-up needed)

`move_stage`'s per-stage value snapshotting (added for the Report feature, 20261115000000)
only captures what a *forward* move clears. Backing out of a stage without editing it, then
moving forward again, silently replaces that stage's real snapshot with the carried-over value
(which actually belongs to a different stage) — `move_stage` never clears or restores anything
on a backward move. Accepted as a known gap for this rollout (user decision, 2026-11-16); the
next concrete step is to run this through its own plan-pipeline pass as an immediate follow-up.

## Outstanding

- Decide whether/when to port dev's accumulated features (listed above) to prod.
- Plan and fix the `move_stage` backward-move residual limitation above.
