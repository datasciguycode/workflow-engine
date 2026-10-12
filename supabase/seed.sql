-- Phase 0 isolation-test fixtures (SPEC.md §1A "First run" / "Isolation test").
-- Run as the migration role (service_role / postgres), which bypasses RLS -- this is the only
-- place accounts/workflows/stages get created in v1 (no create_account RPC exists, by design).
--
-- auth.users rows for these two ids must already exist (created via the Auth admin API / dashboard
-- before this file runs) -- see scratchpad notes for how they were created locally.

-- acct_1 / user A
insert into public.accounts (id, name) values
  ('11111111-1111-1111-1111-111111111111', 'Acct 1 (isolation test)');

insert into public.account_members (account_id, user_id, role) values
  ('11111111-1111-1111-1111-111111111111', '8f3a0d26-5d86-4b18-8068-dae74693d42f', 'owner');

insert into public.workflows (id, account_id, name) values
  ('11111111-1111-1111-1111-111111111112', '11111111-1111-1111-1111-111111111111', 'Acct 1 workflow');

insert into public.stages (id, workflow_id, title, sequence_order) values
  ('11111111-1111-1111-1111-111111111113', '11111111-1111-1111-1111-111111111112', 'stage A1', 1),
  ('11111111-1111-1111-1111-111111111114', '11111111-1111-1111-1111-111111111112', 'stage A2', 2);

-- acct_2 / user B
insert into public.accounts (id, name) values
  ('22222222-2222-2222-2222-222222222221', 'Acct 2 (isolation test)');

insert into public.account_members (account_id, user_id, role) values
  ('22222222-2222-2222-2222-222222222221', '62e02840-6ac9-4c69-965d-c8f647a5bb18', 'owner');

insert into public.workflows (id, account_id, name) values
  ('22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222221', 'Acct 2 workflow');

insert into public.stages (id, workflow_id, title, sequence_order) values
  ('22222222-2222-2222-2222-222222222223', '22222222-2222-2222-2222-222222222222', 'stage B1', 1),
  ('22222222-2222-2222-2222-222222222224', '22222222-2222-2222-2222-222222222222', 'stage B2', 2);

-- A pre-existing item in each account, owned via create_item but inserted directly here (service
-- role bypasses RLS) since the isolation test needs something to already be there to read/move.
insert into public.items (id, workflow_id, stage_id, data) values
  ('11111111-1111-1111-1111-111111111115', '11111111-1111-1111-1111-111111111112',
   '11111111-1111-1111-1111-111111111113', '{"note": "acct 1 item"}');

insert into public.items (id, workflow_id, stage_id, data) values
  ('22222222-2222-2222-2222-222222222225', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222223', '{"note": "acct 2 item"}');
