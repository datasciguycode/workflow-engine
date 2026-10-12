-- Phase 0: minimal core schema + access control.
-- Workflow-shape fields (is_initial, is_terminal, enforce_stage_order, item_events.seq) are
-- deliberately NOT included here -- they're added in later migrations when a workflow port
-- actually needs them (SPEC.md §0, "discover, don't pre-assert").

create extension if not exists pgcrypto;

-- ===========================================================================
-- 1. Core tables (SPEC.md §1)
-- ===========================================================================

create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table public.account_members (
  account_id uuid not null references public.accounts (id),
  user_id uuid not null,
  role text not null check (role in ('owner', 'member')),
  created_at timestamptz not null default now(),
  primary key (account_id, user_id)
);

create table public.workflows (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts (id),
  name text not null,
  created_at timestamptz not null default now()
);

create table public.stages (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null references public.workflows (id),
  title text not null,
  sequence_order integer,
  created_at timestamptz not null default now(),
  unique (workflow_id, title),
  -- lets items.stage_id carry a composite FK that pins a stage to its own workflow (below).
  unique (id, workflow_id)
);

create table public.items (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null references public.workflows (id),
  stage_id uuid not null,
  data jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- composite FK, not a plain FK on stage_id: proves the stage belongs to this item's own
  -- workflow, not just that the stage exists somewhere (SPEC.md §1, "Cross-workflow integrity").
  foreign key (stage_id, workflow_id) references public.stages (id, workflow_id)
);

create table public.item_events (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.items (id),
  event_type text not null check (
    event_type in ('item.created', 'item.stage_changed', 'item.data_changed', 'item.note_added')
  ),
  from_stage_id uuid references public.stages (id),
  to_stage_id uuid references public.stages (id),
  -- server-derived, never client-supplied (SPEC.md §1A); no ON DELETE by design -- an
  -- audit log shouldn't let its rows go stale-silent when a user is removed.
  actor uuid not null default auth.uid() references auth.users (id),
  data jsonb,
  created_at timestamptz not null default now()
);

-- Supporting indexes for the access-control policy checks below (SPEC.md §1).
create index on public.account_members (user_id, account_id);
create index on public.workflows (account_id);
create index on public.stages (workflow_id);
create index on public.items (workflow_id);

-- ===========================================================================
-- 2. Access-control helpers (SPEC.md §1A)
-- ===========================================================================
-- Not exposed to PostgREST (not in the API schema list), so these can't be called as RPCs.
-- SECURITY DEFINER only to break the self-referencing-RLS recursion on account_members; each
-- helper only ever answers about the caller (auth.uid()), so it reveals nothing new to them.

create schema if not exists private;

create function private.is_member(acct uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.account_members
    where account_id = acct and user_id = auth.uid()
  );
$$;

create function private.is_owner(acct uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.account_members
    where account_id = acct and user_id = auth.uid() and role = 'owner'
  );
$$;

create function private.can_access_workflow(wf uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.workflows w
    join public.account_members m on m.account_id = w.account_id
    where w.id = wf and m.user_id = auth.uid()
  );
$$;

create function private.can_access_item(it uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.items i
    join public.workflows w on w.id = i.workflow_id
    join public.account_members m on m.account_id = w.account_id
    where i.id = it and m.user_id = auth.uid()
  );
$$;

revoke all on function private.is_member(uuid) from public;
revoke all on function private.is_owner(uuid) from public;
revoke all on function private.can_access_workflow(uuid) from public;
revoke all on function private.can_access_item(uuid) from public;

grant usage on schema private to authenticated;
grant execute on function private.is_member(uuid) to authenticated;
grant execute on function private.is_owner(uuid) to authenticated;
grant execute on function private.can_access_workflow(uuid) to authenticated;
grant execute on function private.can_access_item(uuid) to authenticated;

-- ===========================================================================
-- 3. Row-level security (SPEC.md §1A policy table)
-- ===========================================================================

alter table public.accounts enable row level security;
alter table public.account_members enable row level security;
alter table public.workflows enable row level security;
alter table public.stages enable row level security;
alter table public.items enable row level security;
alter table public.item_events enable row level security;

-- accounts: no INSERT policy -- accounts only ever come from the seed file (service role,
-- which bypasses RLS). No DELETE policy in v1.
create policy accounts_select on public.accounts
  for select to authenticated
  using (private.is_member(id));

create policy accounts_update on public.accounts
  for update to authenticated
  using (private.is_owner(id))
  with check (private.is_owner(id));

-- account_members
create policy account_members_select on public.account_members
  for select to authenticated
  using (private.is_member(account_id));

create policy account_members_insert on public.account_members
  for insert to authenticated
  with check (private.is_owner(account_id));

create policy account_members_update on public.account_members
  for update to authenticated
  using (private.is_owner(account_id))
  with check (private.is_owner(account_id));

create policy account_members_delete on public.account_members
  for delete to authenticated
  using (private.is_owner(account_id));

-- workflows: no DELETE policy in v1.
create policy workflows_select on public.workflows
  for select to authenticated
  using (private.is_member(account_id));

create policy workflows_insert on public.workflows
  for insert to authenticated
  with check (private.is_member(account_id));

create policy workflows_update on public.workflows
  for update to authenticated
  using (private.is_member(account_id))
  with check (private.is_member(account_id));

-- stages: no DELETE policy in v1 (stage deletion is the deferred migration problem, SPEC.md §8).
create policy stages_select on public.stages
  for select to authenticated
  using (private.can_access_workflow(workflow_id));

create policy stages_insert on public.stages
  for insert to authenticated
  with check (private.can_access_workflow(workflow_id));

create policy stages_update on public.stages
  for update to authenticated
  using (private.can_access_workflow(workflow_id))
  with check (private.can_access_workflow(workflow_id));

-- items: no DELETE policy in v1.
create policy items_select on public.items
  for select to authenticated
  using (private.can_access_workflow(workflow_id));

create policy items_insert on public.items
  for insert to authenticated
  with check (private.can_access_workflow(workflow_id));

create policy items_update on public.items
  for update to authenticated
  using (private.can_access_workflow(workflow_id))
  with check (private.can_access_workflow(workflow_id));

-- item_events: append-only at the database level -- no UPDATE or DELETE policy, ever.
create policy item_events_select on public.item_events
  for select to authenticated
  using (private.can_access_item(item_id));

create policy item_events_insert on public.item_events
  for insert to authenticated
  with check (private.can_access_item(item_id) and actor = auth.uid());

-- ===========================================================================
-- 4. Write RPCs (SPEC.md §2) -- SECURITY INVOKER, so RLS above applies inside them too.
--    Phase 0: no validation beyond FK integrity (is_initial/enforce_stage_order don't exist yet).
-- ===========================================================================

create function public.create_item(p_workflow_id uuid, p_stage_id uuid, p_data jsonb default '{}')
returns public.items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item public.items;
begin
  insert into public.items (workflow_id, stage_id, data)
  values (p_workflow_id, p_stage_id, coalesce(p_data, '{}'::jsonb))
  returning * into v_item;

  insert into public.item_events (item_id, event_type)
  values (v_item.id, 'item.created');

  return v_item;
end;
$$;

create function public.move_stage(p_item_id uuid, p_to_stage_id uuid)
returns public.items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item public.items;
  v_from_stage uuid;
begin
  select * into v_item from public.items where id = p_item_id for update;
  if not found then
    raise exception 'item not found';
  end if;

  v_from_stage := v_item.stage_id;

  update public.items
  set stage_id = p_to_stage_id, updated_at = now()
  where id = p_item_id
  returning * into v_item;

  insert into public.item_events (item_id, event_type, from_stage_id, to_stage_id)
  values (p_item_id, 'item.stage_changed', v_from_stage, p_to_stage_id);

  return v_item;
end;
$$;

create function public.update_data(p_item_id uuid, p_patch jsonb)
returns public.items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item public.items;
  v_delete_keys text[];
begin
  select * into v_item from public.items where id = p_item_id for update;
  if not found then
    raise exception 'item not found';
  end if;

  -- top-level merge patch (SPEC.md §0/S4): each key replaces wholesale, a top-level null
  -- deletes the key. Not jsonb_strip_nulls, which would also strip legitimate nested nulls.
  select array_agg(key) into v_delete_keys
  from jsonb_each(p_patch)
  where value = 'null'::jsonb;

  update public.items
  set data = (data || p_patch) - coalesce(v_delete_keys, array[]::text[]),
      updated_at = now()
  where id = p_item_id
  returning * into v_item;

  insert into public.item_events (item_id, event_type, data)
  values (p_item_id, 'item.data_changed', p_patch);

  return v_item;
end;
$$;

create function public.add_note(p_item_id uuid, p_note text)
returns public.item_events
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_event public.item_events;
begin
  if not exists (select 1 from public.items where id = p_item_id) then
    raise exception 'item not found';
  end if;

  insert into public.item_events (item_id, event_type, data)
  values (p_item_id, 'item.note_added', to_jsonb(p_note))
  returning * into v_event;

  return v_event;
end;
$$;

revoke all on function public.create_item(uuid, uuid, jsonb) from public;
revoke all on function public.move_stage(uuid, uuid) from public;
revoke all on function public.update_data(uuid, jsonb) from public;
revoke all on function public.add_note(uuid, text) from public;

grant execute on function public.create_item(uuid, uuid, jsonb) to authenticated;
grant execute on function public.move_stage(uuid, uuid) to authenticated;
grant execute on function public.update_data(uuid, jsonb) to authenticated;
grant execute on function public.add_note(uuid, text) to authenticated;
