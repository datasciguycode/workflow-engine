-- Continuing the optional_checklist rollout from the prior migration, now that the anchor
-- (required) field for each remaining multi-field stage has been decided (2026-11-11):
-- In Progress requires work_started_at, not technician; Invoicing requires invoice_amount, not
-- invoice_number (planned to be auto-generated once invoice generation exists); Payment Receipt
-- Submitted requires payment_method, not receipt_number (same reasoning -- auto-generated later).
-- Matched by title since stage ids differ between dev and prod (same pattern as before).

update public.stages set optional_checklist = '["technician"]'::jsonb
  where title = 'in_progress' and checklist @> '["technician"]'::jsonb;

update public.stages set optional_checklist = '["invoice_number"]'::jsonb
  where title = 'invoicing' and checklist @> '["invoice_number"]'::jsonb;

update public.stages set optional_checklist = '["receipt_number"]'::jsonb
  where title = 'payment_receipt_submitted' and checklist @> '["receipt_number"]'::jsonb;
