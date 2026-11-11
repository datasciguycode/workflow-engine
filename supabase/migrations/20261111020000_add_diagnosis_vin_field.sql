-- Adds "vin" to Diagnosis's checklist, as an optional field alongside "parts" (2026-11-11):
-- the VIN plate/sticker is only ever visible once the car is physically in front of the
-- mechanic, which is Diagnosis, not Intake (a phone call can't photograph a plate). Optional
-- for the same reason "parts" is -- not every job needs it captured. Matched by title since
-- stage ids differ between dev and prod (same pattern as prior content-only migrations).

update public.stages
set
  checklist = checklist || '["vin"]'::jsonb,
  optional_checklist = optional_checklist || '["vin"]'::jsonb
where title = 'diagnosis'
  and not (checklist @> '["vin"]'::jsonb);
