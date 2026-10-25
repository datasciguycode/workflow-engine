-- Dev fixtures: Phase 0 isolation-test accounts, plus the mechanic workflow port (Phase 1+).
-- Run as the migration role (service_role / postgres), which bypasses RLS -- this is the only
-- place accounts/workflows/stages get created in v1 (no create_account RPC exists, by design).
-- Idempotent (ON CONFLICT DO NOTHING) so it's safe to re-run as new fixtures are added here.
--
-- auth.users rows for the fixture ids below must already exist (created via the Auth admin API
-- before this file runs). `supabase db reset` wipes auth.users every time it runs -- it does NOT
-- survive a reset on its own -- so run scripts/ensure_dev_auth_users.py (idempotent) once after
-- every `supabase db reset` / `supabase start` on a fresh volume, or any write that triggers an
-- item_events insert will fail its actor->auth.users foreign key (bug found 2026-10-16: a reset
-- had silently broken this for a full day because reads and tool-less chat replies don't exercise
-- that FK at all).

-- acct_1 / user A
insert into public.accounts (id, name) values
  ('11111111-1111-1111-1111-111111111111', 'Acct 1 (isolation test)')
  on conflict (id) do nothing;

insert into public.account_members (account_id, user_id, role, display_name) values
  ('11111111-1111-1111-1111-111111111111', '8f3a0d26-5d86-4b18-8068-dae74693d42f', 'owner', 'Dana (dispatcher)')
  on conflict (account_id, user_id) do nothing;

-- Second acct_1 member for Phase 1b's decline/reopen test (SPEC.md §7's exit check needs two
-- distinct actors -- dispatcher and mechanic -- not two separate accounts). auth.users row
-- created via the Auth admin API, same as the two isolation-test users above.
insert into public.account_members (account_id, user_id, role, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'e5445381-e390-4943-bc80-91ba0c60a048', 'member', 'Max (mechanic)')
  on conflict (account_id, user_id) do nothing;

-- Phase 4a: display_name added to account_members after these rows already existed locally --
-- ON CONFLICT DO NOTHING above won't set it on a re-run, so a direct UPDATE handles that (same
-- gotcha as is_terminal on payment_receipt_submitted below).
update public.account_members set display_name = 'Dana (dispatcher)'
  where user_id = '8f3a0d26-5d86-4b18-8068-dae74693d42f' and display_name is null;
update public.account_members set display_name = 'Max (mechanic)'
  where user_id = 'e5445381-e390-4943-bc80-91ba0c60a048' and display_name is null;

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

insert into public.workflows (id, account_id, name, item_label) values
  ('33333333-3333-3333-3333-333333333330', '11111111-1111-1111-1111-111111111111', 'Joe''s Auto Repair', 'job')
  on conflict (id) do nothing;

update public.workflows set item_label = 'job'
  where id = '33333333-3333-3333-3333-333333333330' and item_label = 'item';

insert into public.stages (id, workflow_id, title, sequence_order, is_initial) values
  ('33333333-3333-3333-3333-333333333331', '33333333-3333-3333-3333-333333333330', 'intake', 1, true),
  ('33333333-3333-3333-3333-333333333332', '33333333-3333-3333-3333-333333333330', 'scheduling', 2, false),
  ('33333333-3333-3333-3333-333333333333', '33333333-3333-3333-3333-333333333330', 'diagnosis', 3, false),
  ('33333333-3333-3333-3333-333333333334', '33333333-3333-3333-3333-333333333330', 'estimated', 4, false),
  ('33333333-3333-3333-3333-333333333335', '33333333-3333-3333-3333-333333333330', 'approval', 5, false),
  ('33333333-3333-3333-3333-333333333336', '33333333-3333-3333-3333-333333333330', 'in_progress', 6, false),
  ('33333333-3333-3333-3333-333333333337', '33333333-3333-3333-3333-333333333330', 'invoicing', 7, false),
  ('33333333-3333-3333-3333-333333333338', '33333333-3333-3333-3333-333333333330', 'payment_receipt_submitted', 8, false)
  on conflict (id) do nothing;

-- Phase 1b (SPEC.md §4 revised 2026-10-13): payment_receipt_submitted and closed are the two
-- terminal stages -- invoicing is not (being invoiced isn't "done" until payment is received and
-- the receipt is sent). ON CONFLICT DO NOTHING won't set is_terminal on the already-existing
-- payment_receipt_submitted row, so a direct UPDATE handles that one (same gotcha as is_initial
-- in Phase 1).
insert into public.stages (id, workflow_id, title, sequence_order, is_initial, is_terminal) values
  ('33333333-3333-3333-3333-333333333339', '33333333-3333-3333-3333-333333333330', 'closed', null, false, true)
  on conflict (id) do nothing;

update public.stages set is_terminal = true
  where id = '33333333-3333-3333-3333-333333333338' and not is_terminal;

-- ===========================================================================
-- Phase 3: SDLC workflow (SPEC.md §5), the second proof case -- exercises
-- enforce_stage_order = true, which the mechanic workflow never needed.
-- ===========================================================================

insert into public.workflows (id, account_id, name, enforce_stage_order, item_label) values
  ('44444444-4444-4444-4444-444444444440', '11111111-1111-1111-1111-111111111111', 'Feature Pipeline', true, 'ticket')
  on conflict (id) do nothing;

update public.workflows set item_label = 'ticket'
  where id = '44444444-4444-4444-4444-444444444440' and item_label = 'item';

insert into public.stages (id, workflow_id, title, sequence_order, is_initial, is_terminal) values
  ('44444444-4444-4444-4444-444444444441', '44444444-4444-4444-4444-444444444440', 'spec', 1, true, false),
  ('44444444-4444-4444-4444-444444444442', '44444444-4444-4444-4444-444444444440', 'prototype', 2, false, false),
  ('44444444-4444-4444-4444-444444444443', '44444444-4444-4444-4444-444444444440', 'refactor', 3, false, false),
  ('44444444-4444-4444-4444-444444444444', '44444444-4444-4444-4444-444444444440', 'test', 4, false, false),
  ('44444444-4444-4444-4444-444444444445', '44444444-4444-4444-4444-444444444440', 'deploy', 5, false, true)
  on conflict (id) do nothing;
