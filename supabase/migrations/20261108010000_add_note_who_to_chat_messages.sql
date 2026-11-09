-- The chat box's "Save as note" checkbox (2026-11-08) writes a note directly, bypassing the
-- agent, and logs a "note" confirmation line into the same chat_messages table as user/agent/
-- error -- so a page reload still shows that confirmation the same way every other chat line
-- already persists. Widen the who check to allow it.

alter table public.chat_messages drop constraint chat_messages_who_check;
alter table public.chat_messages add constraint chat_messages_who_check
  check (who in ('user', 'agent', 'error', 'note'));
