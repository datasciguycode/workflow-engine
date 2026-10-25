-- Phase 5: persist chat as the only history record (2026-10-21 UI redesign landed on "chat is the
-- log, no separate structured event view"), but the chat itself only ever lived in the Blazor
-- component's in-memory _chatLog -- a page reload wiped it completely (caught 2026-10-23: user
-- reloaded WorkflowDetail and every conversation, including the job's own creation chat, was gone).
-- This table makes chat durable and reloadable, tagged the same way the UI already tags it: by
-- which item/stage was selected in the UI when the message was sent (both nullable -- a message
-- sent from the Jobs list, before any item is selected, has item_id null; one sent from a job's own
-- page, before any stage is selected, has stage_id null).

create table public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null references public.workflows (id),
  item_id uuid references public.items (id),
  stage_id uuid references public.stages (id),
  who text not null check (who in ('user', 'agent', 'error')),
  body text not null,
  created_at timestamptz not null default now()
);

create index on public.chat_messages (workflow_id, item_id, stage_id, created_at);

alter table public.chat_messages enable row level security;

-- Append-only, like item_events -- no UPDATE or DELETE policy.
create policy chat_messages_select on public.chat_messages
  for select to authenticated
  using (private.can_access_workflow(workflow_id));

create policy chat_messages_insert on public.chat_messages
  for insert to authenticated
  with check (private.can_access_workflow(workflow_id));
