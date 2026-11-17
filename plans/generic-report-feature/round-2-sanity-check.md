# Round 2 Sanity Check — Generic Report Feature

## Verdict

No plan-blocking issues. Both of the specifically-requested correctness checks hold up under
direct verification (not just re-reading the reasoning):

**Double-counting fix (`from_stage_id` keying).** Hand-traced Step 4's check-4 scenario
(breakfast→lunch, back, correct, breakfast→brunch) against the actual `move_stage` body
(20261113000000) and the `report_series` dedupe logic. From-stage-id keying correctly yields
60 (breakfast 40 + brunch 20); independently reproduced the plan's "`to_stage_id` would give
75" counterfactual by simulating that alternate keying (brunch-arrivals dedupe to 35,
lunch-arrivals dedupe to 40, sum 75) — confirming the stated reasoning about forward-skips
under `enforce_stage_order = false` is correct, not just asserted. The "live value supersedes
its own stage's old snapshot" rule is also correct and necessary (without it, correcting a
backed-into stage would double-count). The disclosed residual limitation — backing out of a
stage without editing, then moving forward again, silently replaces that stage's real snapshot
with the carried-over (actually-belongs-to-a-different-stage) value — is accurately
characterized against the code (`move_stage` never clears or restores on backward moves) and
is reasonably scoped out rather than built here.

**CHECK constraint fix.** Built the literal CHECK expression as a temp-table constraint on live
Postgres and threw NULL-passthrough traps at it directly: JSON null-valued period/fields keys,
non-string period values (object/array/bool/number, which `->>` stringifies rather than
nulling), fields as an object instead of array, and a bare scalar `report_config`. Every case
was correctly rejected; the valid case and the `report_config IS NULL` case were correctly
accepted. No NULL-passthrough gap exists. Also separately verified supporting claims the plan
leans on (`jsonb_object_agg` over zero rows → NULL, `?`/`?&`/`->`/`->>` returning NULL/false
rather than erroring on NULL or scalar jsonb) against live Postgres, and confirmed
`item_events.seq` is a global `bigserial` (no tie risk in `distinct on ... order by seq desc`),
`items.stage_id` is `NOT NULL` (so `from_stage_id` is never null on `stage_changed`), and
`WorkflowSummary`'s 3-arg call sites still compile against the new 4-arg record with a trailing
default.

## Findings (none blocking, ranked by severity)

1. **(Worth considering — critique/cut-this)** `private.jsonb_numeric`'s string-parsing branch
   is untested and, under this plan's own scope, unreachable. It parses `"$1,250.00"`-style
   strings via regex, justified by "a $1,250 string from chat shouldn't silently zero a revenue
   report." But per the plan's own ground-truth, Nutrition Tracker's macros are always JSON
   numbers, and the mechanic's `estimate_amount`/`invoice_amount` are also JSON numbers — and
   committing a mechanic config is explicitly out of scope. Neither Step 4's checks nor Step
   7's dry run ever calls `jsonb_numeric` with a string argument, so this regex path ships with
   zero test coverage and no current caller. Fix: either add one assertion to the Step 4 `DO`
   block exercising a string input (`'"$1,250.00"'`, a garbage string, an empty string), or cut
   the branch down to `case jsonb_typeof(v) when 'number' then (v #>> '{}')::numeric end` until
   a real string-valued numeric field exists.

2. **(Worth considering — alternative)** `report_series` has no bound on `p_to - p_from`.
   Unlike the plan's self-rolling-back `DO` blocks, this RPC is permanently
   `grant execute ... to authenticated` and callable directly by any caller for workflows they
   can access. A malformed or buggy client call with a huge range scans all of that workflow's
   `item_events` with no caller-visible cost signal. Harmless at current volumes, but worth a
   defensive clamp (e.g. `if p_to - p_from > 3660 then raise exception ...`).

3. **(Worth considering — minor)** CHECK allows `report_config.fields = []`. A
   migration-authored config with an empty fields array passes the shape CHECK and silently
   produces a Report link to a page with zero field cards. Trivial to tighten with
   `jsonb_array_length(report_config -> 'fields') > 0` in the CHECK if desired; low risk since
   config is migration-authored, not user-authored.

4. **(Worth considering — minor)** Step 7's dry run mixes timezones: `p_to = current_date`
   (server/UTC date) against `p_tz = 'America/Chicago'`. Since Chicago is always behind UTC
   this never clips real data today, but it's a coincidence of direction, not a guarantee — the
   Step 4 block already does this correctly (`v_day := (now() at time zone
   'America/Chicago')::date`); Step 7 should match that pattern.

5. **(Worth considering — minor)** Step 1's migration body is pseudocode, not literal SQL
   ("unchanged from 20261113000000 up to and including the `v_shared_keys` computation").
   Step 4's diff check catches unintended extra differences, but doesn't verify the "NEW" lines
   were transcribed with correct semantics before that diff runs. Consider writing the full
   literal function body now rather than a "copy X, change only Y" instruction.

6. **(Worth considering — minor)** `agg: avg` is applied twice (per-item across stage-visits,
   then per-period across items) with no weighting, so an "average of averages" can diverge
   from a flat average when items contribute different numbers of underlying values. No shipped
   config (Nutrition, or the Step 7 mechanic dry run) actually uses `avg`, so this is currently
   moot — worth a one-line doc note for whoever configures the first `avg` field.

## Summary

- Findings: 1 moderate (borderline worth-considering) + 5 minor (worth-considering) = 6 total.
  0 "must address before implementation."
- The two things this round specifically needed adversarial re-verification on — the
  `from_stage_id` dedupe keying rationale (including its named trade-off) and the CHECK
  constraint's NULL-safety — both check out under direct simulation and live-Postgres testing.
- Nothing here blocks the plan as written. The findings above are refinements, not corrections
  of a wrong design.

Files read: plans/generic-report-feature/round-2-draft.md, CLAUDE.md, PROGRESS.md,
supabase/migrations/20261013180000_phase3_enforce_stage_order.sql,
supabase/migrations/20261113000000_move_stage_clears_shared_fields.sql,
supabase/migrations/20261012035437_phase0_core_schema.sql,
supabase/migrations/20261104000000_grant_item_events_seq_usage.sql,
supabase/migrations/20261020200000_fix_create_item_stage_id_overload.sql,
supabase/migrations/20261108030000_add_search_items.sql, web/Services/WorkflowApiClient.cs,
web/Pages/WorkflowDetail.razor, web/wwwroot/index.html. Verified live against the project's
local Supabase/Postgres instance via `docker exec supabase_db_workflow-app psql`.
