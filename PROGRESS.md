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

## Rideshare Mileage/Expenses workflows — shipped on dev

Vetted plan (plan-pipeline, approved-with-changes): `plans/uber-mileage-tracker/final-plan.md`.
Two dev-only workflows for Uber/Lyft drivers — "Rideshare Mileage" (shift-level odometer-photo
scan at Start/End, derived miles/hours, optional tolls/parking/earnings) and "Rideshare Expenses"
(flat category/amount/date log) — plus four generic report-engine extensions (signed derived
weights, hidden fields, timestamp parsing, item_date_key) that the Mileage workflow needs. GPS/
reverse-geocoding was dropped in favor of plain manual address text fields.

Steps 1–6 all done and pushed: migrations, edge functions (`scan-odometer`, date-aware
`agent-loop`), and web UI (odometer capture block, `_usd`/date-only field rendering, Jobs-list
closed rule, display-name disambiguation). Live-tested on dev via phone.

## Shared across workflows, from live testing (2026-11-25/26)

- **Date filter** replaced/augmented the old hide-closed toggle: Nutrition Tracker ("meal date"
  item_label) shows one date-defaulted-to-today picker instead of hide-closed, since it's one
  item per calendar day and hide-closed was hiding the just-logged item. Other job-style
  workflows kept Show/Hide closed and got the same date picker as an additive narrowing filter,
  both defaulting to today.
- **`PhotoScanButton` shared component** (`web/Shared/PhotoScanButton.razor`) + a shared
  `ReadPhotoAsJpegBase64Async` helper in `WorkflowDetail.razor` dedupe the button/input/error
  markup and resize/base64 boilerplate across Scan VIN/Plate/odometer, while leaving each scan
  type's own extra fields and result handling untouched (plan: `plans/tingly-whistling-scroll.md`
  if still present under `~/.claude/plans/`, otherwise see commit `bf90e90`).
- Scan Plate briefly grew a "measured grams" either/or field (commits `66a5473`, `9eab5ce`) and
  it was reverted the same day (`5f37b1c`) once the user realized they can just scan the kitchen
  scale's own reading instead — portion-of-photo is the only input again.

## Outstanding

- Decide whether/when to port dev's accumulated features (listed above) to prod.
- `closed_at` migration (`20261119000000`, committed to dev's repo) still needs to be applied to
  prod's live DB and to prod's `bootstrap.sql`/`create_test_account.sql` — tracked in this
  session's memory as a to-do, not yet resumed.
