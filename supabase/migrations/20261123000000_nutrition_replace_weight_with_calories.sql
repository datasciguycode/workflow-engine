-- Nutrition Tracker: replace the per-meal body-weight field with a directly-entered Calories
-- field (2026-11-23, user request). weight_lbs was logged on every stage but deliberately never
-- reported (see 20261115010000); calories_kcal takes its slot instead and, unlike weight, DOES
-- feed the weekly report -- it replaces the old derived "calories" report field (protein_g*4 +
-- carbs_g*4 + fat_g*9), which was only ever an Atwater-factor approximation. A real food label
-- printed calorie count (or the Scan Plate estimate, updated alongside it) is more accurate than
-- that formula, especially for packaged food where label rounding and fiber/alcohol calories
-- don't match the simple per-gram factors.
--
-- item_requires stays ["protein_g","carbs_g","fat_g"] -- a day still counts toward the weekly
-- average on those three alone, same as before. A day with macros but no calories entered just
-- averages calories over however many meals did have it, same soft handling as fiber_g/sugar_g.

update public.stages
set
  checklist = (checklist - 'weight_lbs') || '["calories_kcal"]'::jsonb,
  optional_checklist = (optional_checklist - 'weight_lbs') || '["calories_kcal"]'::jsonb
where workflow_id in (select id from public.workflows where name = 'Nutrition Tracker')
  and checklist @> '["weight_lbs"]'::jsonb;

update public.workflows
set report_config = jsonb_set(
  report_config,
  '{fields,0}',
  '{"key": "calories_kcal", "label": "Calories", "unit": "kcal", "item_agg": "sum", "period_agg": "avg"}'::jsonb
)
where name = 'Nutrition Tracker'
  and report_config -> 'fields' -> 0 ->> 'key' = 'calories';
