-- RLS policies (phase0) define *which* rows `authenticated` can touch, but Postgres also
-- requires a table-level GRANT before a policy is even consulted -- without it every request
-- fails with "permission denied for table X" (PostgREST maps this to 403), regardless of RLS.
-- These grants were missing from the original schema migration; scoped to match exactly what
-- each table's existing policies already allow (SPEC.md §1A policy table).

grant select, update on public.accounts to authenticated;
grant select, insert, update, delete on public.account_members to authenticated;
grant select, insert, update on public.workflows to authenticated;
grant select, insert, update on public.stages to authenticated;
grant select, insert, update on public.items to authenticated;
grant select, insert on public.item_events to authenticated;
grant select, insert on public.chat_messages to authenticated;
