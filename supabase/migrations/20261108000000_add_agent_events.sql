-- Agent telemetry: usage (token counts per agent-loop call) and error (failed tool calls /
-- agent-loop failures) in one combined table, discriminated by event_type. Decided 2026-11-08
-- during a discussion about tracking per-job context growth and surfacing agent errors
-- somewhere durable/queryable, rather than only as a transient chat line or ephemeral function
-- log. Append-only, same as item_events -- no update or delete policy, ever.

create table public.agent_events (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null references public.workflows (id),
  -- nullable: a message sent with no job open (Jobs list / New Job screen) has no item yet.
  item_id uuid references public.items (id),
  event_type text not null check (event_type in ('usage', 'error')),
  -- usage rows: token counts from that Anthropic API call's response.usage.
  input_tokens integer,
  output_tokens integer,
  -- error rows: a short message describing what failed (a rejected tool call, an API error).
  error_message text,
  created_at timestamptz not null default now()
);

alter table public.agent_events enable row level security;

create policy agent_events_select on public.agent_events
  for select to authenticated
  using (private.can_access_workflow(workflow_id));

create policy agent_events_insert on public.agent_events
  for insert to authenticated
  with check (private.can_access_workflow(workflow_id));

grant select, insert on public.agent_events to authenticated;
