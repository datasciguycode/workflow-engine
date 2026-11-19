-- Rideshare Mileage/Expenses workflows (plans/uber-mileage-tracker/final-plan.md, Step 2).
--
-- Two dev-only workflows for Uber/Lyft drivers:
-- - "Rideshare Mileage" tracks the shift as the unit (app on to app off), not the ride, because
--   a per-shift odometer log captures deadhead/waiting miles a per-ride log misses, avoids
--   double-counting stacked rides, and needs only two photos a day, parked (see final-plan.md
--   SS2). `platform` is the business-purpose element of the substantiation record (SS3) and is
--   required on Start, so Complete Stage can't appear without it.
-- - "Rideshare Expenses" is a flat category/amount/date log, separate from the shift lifecycle
--   because expenses aren't tied to a shift and the report engine allows only one
--   report_config/period per workflow (Mileage is weekly, Expenses is monthly).
--
-- Key conventions: `{prefix}_odometer` / `{prefix}_time` / `{prefix}_address` on Start/End,
-- `*_usd` for every dollar amount. Depends on 20261120000000 (signed weights, hidden fields,
-- parse: "timestamp", item_date_key) -- the report_config below uses all four.
--
-- Matching follows the Nutrition Tracker precedent (20261112000000): the account is matched via
-- 'Joe''s Auto Repair', workflows are inserted only `where not exists` (workflows.name isn't
-- unique), and stages use `on conflict (workflow_id, title) do nothing` (stages has
-- unique (workflow_id, title)).

insert into public.workflows (account_id, name, item_label)
select w.account_id, v.name, v.item_label
from public.workflows w
cross join (values ('Rideshare Mileage', 'shift'), ('Rideshare Expenses', 'expense')) as v(name, item_label)
where w.name = 'Joe''s Auto Repair'
  and not exists (select 1 from public.workflows x where x.name = v.name);

-- Shift: Start (initial) -> End (terminal). platform is REQUIRED on Start: it is the
-- business-purpose element of the substantiation record (see header), so Complete Stage must
-- not appear without it. The client pre-fills it from the previous shift.
insert into public.stages (workflow_id, title, sequence_order, is_initial, is_terminal, checklist, optional_checklist)
select w.id, s.title, s.seq, s.is_initial, s.is_terminal, s.checklist, s.optional
from public.workflows w
cross join (values
  ('start', 1, true,  false,
   '["start_odometer","start_time","platform","start_address"]'::jsonb,
   '["start_address"]'::jsonb),
  ('end',   2, false, true,
   '["end_odometer","end_time","end_address","tolls_usd","parking_usd","earnings_usd"]'::jsonb,
   '["end_address","tolls_usd","parking_usd","earnings_usd"]'::jsonb)
) as s(title, seq, is_initial, is_terminal, checklist, optional)
where w.name = 'Rideshare Mileage'
on conflict (workflow_id, title) do nothing;

-- Expense: one stage, both initial and terminal (a flat log). Every field optional: a missing
-- date falls back to created_at's local day; categories are mutually optional. The free-text
-- field is "description", not "note", so the agent doesn't confuse it with its add_note tool.
insert into public.stages (workflow_id, title, sequence_order, is_initial, is_terminal, checklist, optional_checklist)
select w.id, 'logged', 1, true, true,
  '["date","phone_usd","supplies_usd","other_usd","gas_usd","maintenance_usd","insurance_usd","description"]'::jsonb,
  '["date","phone_usd","supplies_usd","other_usd","gas_usd","maintenance_usd","insurance_usd","description"]'::jsonb
from public.workflows w
where w.name = 'Rideshare Expenses'
on conflict (workflow_id, title) do nothing;

update public.workflows
set report_config = '{
  "period": "week",
  "item_noun": "shift",
  "item_date_key": "start_time",
  "note": "For taxes, also download your Uber/Lyft weekly trip history and annual tax summary and keep them with this log. This log covers the miles they don''t report (driving to pickups, waiting).",
  "fields": [
    {"key": "miles",  "label": "Business miles", "unit": "mi", "period_agg": "sum",
     "weights": {"end_odometer": 1, "start_odometer": -1}},
    {"key": "hours",  "label": "Hours online",   "unit": "h",  "period_agg": "sum",
     "weights": {"end_time": 0.000277777777777778, "start_time": -0.000277777777777778}},
    {"key": "earnings_usd", "label": "Earnings", "unit": "$", "unit_position": "prefix",
     "item_agg": "sum", "period_agg": "sum"},
    {"key": "tolls_usd",    "label": "Tolls",    "unit": "$", "unit_position": "prefix",
     "item_agg": "sum", "period_agg": "sum"},
    {"key": "parking_usd",  "label": "Parking",  "unit": "$", "unit_position": "prefix",
     "item_agg": "sum", "period_agg": "sum"},
    {"key": "start_odometer", "hidden": true, "item_agg": "last", "period_agg": "last"},
    {"key": "end_odometer",   "hidden": true, "item_agg": "last", "period_agg": "last"},
    {"key": "start_time", "hidden": true, "parse": "timestamp", "item_agg": "last", "period_agg": "last"},
    {"key": "end_time",   "hidden": true, "parse": "timestamp", "item_agg": "last", "period_agg": "last"}
  ]
}'::jsonb
where name = 'Rideshare Mileage' and report_config is null;

update public.workflows
set report_config = '{
  "period": "month",
  "item_noun": "expense",
  "item_date_key": "date",
  "note": "Keep receipts. Gas, maintenance and insurance count only under the actual-expense method, not on top of the standard mileage rate.",
  "fields": [
    {"key": "phone_usd",       "label": "Phone (business share)",                   "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "supplies_usd",    "label": "Supplies",                                 "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "other_usd",       "label": "Other",                                    "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "gas_usd",         "label": "Gas (actual-expense method only)",         "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "maintenance_usd", "label": "Maintenance (actual-expense method only)", "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"},
    {"key": "insurance_usd",   "label": "Insurance (actual-expense method only)",   "unit": "$", "unit_position": "prefix", "item_agg": "sum", "period_agg": "sum"}
  ]
}'::jsonb
where name = 'Rideshare Expenses' and report_config is null;
