-- Adds "closed_at" to the Closed stage's checklist, as an optional field (2026-11-19): the
-- Closed stage view had no checklist at all, so there was no way to record (or even see) when
-- a job was actually closed. A date field rather than a plain boolean -- the UI already renders
-- date/time checklist fields generically (see FieldText in WorkflowDetail.razor, same path
-- scheduled_at uses), and a timestamp is strictly more useful than true/false for later
-- reporting (turnaround time, closure trends) without adding a second field. Optional because
-- the Closed stage is terminal (no "next stage" to gate) and historical jobs closed before this
-- field existed shouldn't need backfilling to look complete. Matched by title, not stage id,
-- since stage ids differ between dev and prod (same pattern as prior content-only migrations).

update public.stages
set
  checklist = coalesce(checklist, '[]'::jsonb) || '["closed_at"]'::jsonb,
  optional_checklist = optional_checklist || '["closed_at"]'::jsonb
where title = 'closed'
  and not (coalesce(checklist, '[]'::jsonb) @> '["closed_at"]'::jsonb);
