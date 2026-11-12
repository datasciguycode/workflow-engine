-- Nutrition Tracker: a second workflow alongside the mechanic shop's, reusing the same generic
-- items/stages engine as-is (2026-11-12). A day's entry ("meal date") is a normal job-shaped
-- item that moves forward through 5 real sequential stages -- Breakfast (is_initial) through
-- Dinner (is_terminal) -- exactly like a repair job moves through Intake..Closed. No schema or
-- engine change needed: this was settled on specifically because it fits the existing shape,
-- after an earlier all-terminal-peer-stages design (tracked in plans/diet-workflow/, now
-- superseded) turned out to need several new generic capabilities this one doesn't.
--
-- Brunch and Linner (a between-lunch-and-dinner window) exist so a between-meal snack has
-- somewhere to go without needing an open-ended "log unlimited snacks" feature -- any food eaten
-- before the next stage is reached just folds into that stage's one running total (same as
-- adding a second food to a single meal already works: the agent recomputes the stage's total,
-- it doesn't append a list).
--
-- Deliberately out of scope here (not missing, just not part of this pass): no goal-tracking
-- stage (a workflow can only have one is_initial stage, which Breakfast already claims, and
-- goals aren't a daily-recurring thing anyway -- deferred, possibly as its own tiny workflow
-- later), and no cross-day aggregation/trend view (a separate tool, later, reading this same
-- data).

insert into public.workflows (account_id, name, item_label)
select account_id, 'Nutrition Tracker', 'meal date'
from public.workflows
where name = 'Joe''s Auto Repair'
on conflict do nothing;

insert into public.stages (workflow_id, title, sequence_order, is_initial, is_terminal, checklist, optional_checklist)
select w.id, s.title, s.sequence_order, s.is_initial, s.is_terminal,
       '["protein_g","carbs_g","fat_g","fiber_g","sugar_g","weight_lbs"]'::jsonb,
       '["protein_g","carbs_g","fat_g","fiber_g","sugar_g","weight_lbs"]'::jsonb
from public.workflows w
cross join (values
  ('breakfast', 1, true, false),
  ('brunch', 2, false, false),
  ('lunch', 3, false, false),
  ('linner', 4, false, false),
  ('dinner', 5, false, true)
) as s(title, sequence_order, is_initial, is_terminal)
where w.name = 'Nutrition Tracker'
on conflict (workflow_id, title) do nothing;
