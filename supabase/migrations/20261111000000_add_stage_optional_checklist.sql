-- A stage's checklist lists every field typically gathered there, but not every one of them
-- should block the Done-shortcut button -- e.g. Diagnosis's "parts" often isn't known until
-- work actually begins, unlike "diagnosis" itself (2026-11-11). optional_checklist is a subset
-- of checklist: entries listed here still show as a normal checklist item in the UI, they just
-- never factor into whether Done appears. Kept as its own column (not folded into checklist
-- entries becoming objects) so every existing reader of checklist as a plain array of strings
-- keeps working untouched.

alter table public.stages
  add column optional_checklist jsonb not null default '[]'::jsonb;

-- One-time content fix, not a general mechanism -- matched by title since stage ids differ
-- between dev and prod (same pattern as other content-only fixes in this repo).
update public.stages set optional_checklist = '["parts"]'::jsonb
  where title = 'diagnosis' and checklist @> '["parts"]'::jsonb;
