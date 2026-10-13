-- Phase 4a: account_members.display_name (SPEC.md Sec 1, "added in Phase 4 (UI)").
-- Human-readable label for a member within an account, used to render item_events.actor in the
-- UI's chronology list (auth.users isn't readable through the API). Nullable; UI falls back to
-- a short uuid when null. Schema-only -- no RPC or policy changes needed.

alter table public.account_members
  add column display_name text;
