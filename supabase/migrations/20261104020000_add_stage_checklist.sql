-- Stages can optionally list what info is typically gathered at that stage (e.g. intake: name,
-- phone, address) so the agent knows what to ask for instead of only reacting field-by-field.
-- A plain jsonb array of strings, not a child table -- these are just hints read for context,
-- not entities with their own identity/ordering/relationships worth a join everywhere stages are
-- already fetched. Nullable and per-stage, since which fields matter varies by workflow and isn't
-- a hard requirement -- the agent should treat this as a soft guide, not a blocker on moving on.

alter table public.stages
  add column checklist jsonb;
