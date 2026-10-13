-- Phase 1b: port the decline/reopen branch (SPEC.md §7, §4 revised 2026-10-13).
-- Discovers stages.is_terminal -- a reporting/UI hint, not a hard block on items.stage_id writes.
-- Unlike is_initial, more than one is_terminal stage per workflow is allowed (no unique index).
--
-- move_stage and update_data need no changes here: move_stage has never blocked any transition
-- (enforce_stage_order doesn't exist until Phase 3), so backward moves out of a terminal stage
-- already work; update_data already deletes a key on a top-level null and replaces arrays
-- wholesale via `||` (both from Phase 0's merge-patch implementation). This migration is schema
-- only.

alter table public.stages
  add column is_terminal boolean not null default false;
