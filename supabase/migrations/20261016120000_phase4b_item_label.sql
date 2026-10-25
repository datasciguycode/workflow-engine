-- Phase 4b: workflows.item_label -- a per-workflow display word for what the UI generically
-- calls an "item" (e.g. "job" for a mechanic workflow, "ticket"/"project" for an SDLC workflow).
-- Lives on the workflow, not the account: one account can own workflows that each want a
-- different word (confirmed via Dana's account owning both Joe's Auto Repair and Feature
-- Pipeline). Schema-only, defaults to 'item' so existing rows/tests keep working unchanged.

alter table public.workflows
  add column item_label text not null default 'item';
