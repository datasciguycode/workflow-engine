-- Dev fixtures: Phase 0 isolation-test accounts, plus the mechanic workflow port (Phase 1+).
-- Run as the migration role (service_role / postgres), which bypasses RLS -- this is the only
-- place accounts/workflows/stages get created in v1 (no create_account RPC exists, by design).
-- Idempotent (ON CONFLICT DO NOTHING) so it's safe to re-run as new fixtures are added here.
--
-- auth.users rows for the two isolation-test ids must already exist (created via the Auth admin
-- API before this file runs) -- see scripts/phase0_isolation_test.py for how they were created
-- locally.

-- acct_1 / user A
insert into public.accounts (id, name) values
  ('11111111-1111-1111-1111-111111111111', 'Acct 1 (isolation test)')
  on conflict (id) do nothing;

insert into public.account_members (account_id, user_id, role) values
  ('11111111-1111-1111-1111-111111111111', '8f3a0d26-5d86-4b18-8068-dae74693d42f', 'owner')
  on conflict (account_id, user_id) do nothing;

insert into public.workflows (id, account_id, name) values
  ('11111111-1111-1111-1111-111111111112', '11111111-1111-1111-1111-111111111111', 'Acct 1 workflow')
  on conflict (id) do nothing;

insert into public.stages (id, workflow_id, title, sequence_order, is_initial) values
  ('11111111-1111-1111-1111-111111111113', '11111111-1111-1111-1111-111111111112', 'stage A1', 1, true),
  ('11111111-1111-1111-1111-111111111114', '11111111-1111-1111-1111-111111111112', 'stage A2', 2, false)
  on conflict (id) do nothing;

-- acct_2 / user B
insert into public.accounts (id, name) values
  ('22222222-2222-2222-2222-222222222221', 'Acct 2 (isolation test)')
  on conflict (id) do nothing;

insert into public.account_members (account_id, user_id, role) values
  ('22222222-2222-2222-2222-222222222221', '62e02840-6ac9-4c69-965d-c8f647a5bb18', 'owner')
  on conflict (account_id, user_id) do nothing;

insert into public.workflows (id, account_id, name) values
  ('22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222221', 'Acct 2 workflow')
  on conflict (id) do nothing;

insert into public.stages (id, workflow_id, title, sequence_order, is_initial) values
  ('22222222-2222-2222-2222-222222222223', '22222222-2222-2222-2222-222222222222', 'stage B1', 1, true),
  ('22222222-2222-2222-2222-222222222224', '22222222-2222-2222-2222-222222222222', 'stage B2', 2, false)
  on conflict (id) do nothing;

-- A pre-existing item in each account, owned via create_item but inserted directly here (service
-- role bypasses RLS) since the isolation test needs something to already be there to read/move.
insert into public.items (id, workflow_id, stage_id, data) values
  ('11111111-1111-1111-1111-111111111115', '11111111-1111-1111-1111-111111111112',
   '11111111-1111-1111-1111-111111111113', '{"note": "acct 1 item"}')
  on conflict (id) do nothing;

insert into public.items (id, workflow_id, stage_id, data) values
  ('22222222-2222-2222-2222-222222222225', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222223', '{"note": "acct 2 item"}')
  on conflict (id) do nothing;

-- ===========================================================================
-- Phase 1: mechanic workflow port (SPEC.md §4), happy-path stages only --
-- decline/reopen ("closed", is_terminal) is Phase 1b, not built yet.
-- Lives under acct_1, alongside the isolation-test workflow above.
-- ===========================================================================

insert into public.workflows (id, account_id, name) values
  ('33333333-3333-3333-3333-333333333330', '11111111-1111-1111-1111-111111111111', 'Joe''s Auto Repair')
  on conflict (id) do nothing;

insert into public.stages (id, workflow_id, title, sequence_order, is_initial) values
  ('33333333-3333-3333-3333-333333333331', '33333333-3333-3333-3333-333333333330', 'intake', 1, true),
  ('33333333-3333-3333-3333-333333333332', '33333333-3333-3333-3333-333333333330', 'scheduling', 2, false),
  ('33333333-3333-3333-3333-333333333333', '33333333-3333-3333-3333-333333333330', 'diagnosed', 3, false),
  ('33333333-3333-3333-3333-333333333334', '33333333-3333-3333-3333-333333333330', 'estimated', 4, false),
  ('33333333-3333-3333-3333-333333333335', '33333333-3333-3333-3333-333333333330', 'approval', 5, false),
  ('33333333-3333-3333-3333-333333333336', '33333333-3333-3333-3333-333333333330', 'in_progress', 6, false),
  ('33333333-3333-3333-3333-333333333337', '33333333-3333-3333-3333-333333333330', 'invoicing', 7, false),
  ('33333333-3333-3333-3333-333333333338', '33333333-3333-3333-3333-333333333330', 'payment_receipt_submitted', 8, false)
  on conflict (id) do nothing;
