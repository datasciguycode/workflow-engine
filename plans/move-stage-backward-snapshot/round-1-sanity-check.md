# Round 1 Sanity Check — move_stage Backward-Move Snapshot Fix

## Verdict

No plan-blocking issues. I traced the Step 1 migration SQL by hand (`v_cleared`, `v_restored`,
the update's `(data - keys) || restored`, the event insert), cross-checked it against the
actually-committed `20261115000000_move_stage_records_cleared_values.sql` (byte-identical to
what the draft quotes), verified the RLS/grant/index facts it relies on (`item_events_select`
policy, `item_events_item_seq` index, `seq bigserial not null` so "never ties" holds,
`update_data` also takes `for update` so the concurrency claim holds), confirmed the only
non-agent/MCP `move_stage` call site is `WorkflowDetail.razor:808`, confirmed Nutrition's 6-key
checklist matches the test fixtures, and confirmed `report_series_dev_check.sql` only has one
literal `cleared` assertion (so the "one-line update" claim in Step 2 is accurate). I could not
find an actual correctness bug in the restore logic — the per-key "distinct on, order by seq
desc" trace is sound, the null-vs-absent handling (D2) correctly prevents resurrection of
deleted values, and the "no backfill" claim is backed by a real query result (not an
assumption), re-verified immediately pre-push (Step 5.1).

## Findings (none blocking, ranked by severity)

1. **(Alternative, worth considering.)** D3's invariant — "what a stage shows when you return
   to it" and "what the Report counts for that stage" must be the same number — is maintained
   by writing the *same* per-(item, from_stage, key) "latest by seq" algorithm independently in
   two places: the new restore query in `move_stage` (Step 1) and the `raw_segments`/`segments`
   CTEs in `report_series`. They match today because both were hand-written to match, but
   nothing enforces that they stay in sync — a future edit to either (e.g., a tie-break rule, a
   different null-handling tweak) can silently break D3's invariant with no test catching it
   except by coincidence. Concrete alternative: factor the "latest cleared value for (item,
   stage, key)" lookup into one `private` SQL function (or a view) that both `move_stage` and
   `report_series` call, so the two can't drift by construction. Given this is a 2193-char
   plpgsql body and a comparably-sized RPC, this is a reasonable refactor to do now while both
   are being touched, but not required — the current duplication is small and tested, so
   deferring is defensible.

2. **(Critique/cut-this-or-fix-now, worth considering.)** `item_agg: last`'s interaction, which
   the plan flags in Section 5 but declines to fix. I worked through why this is genuinely
   trickier than the plan's framing suggests: `last` already always resolves to the *live*
   segment (seq = +∞) regardless of direction, even before this fix — that part isn't new.
   What *is* new is that after this fix, the live segment's value is the *current* (possibly
   earlier-in-sequence) stage's own correct value, not a carried-over number that happened to
   look like the later stage's. So for a hypothetical config using `item_agg: last` on a key
   shared across stages (e.g., if `weight_lbs` were ever reported), going back a stage would
   make "last" report the earlier stage's older reading as the "latest" value for that
   item/period — which is backwards from what most `last` consumers would intuitively want
   ("the most recently entered value", not "whatever the currently-parked-at stage holds"). The
   plan's own suggested real fix (order by `sequence_order` instead of `seq`) is correct but
   deferred. Since no shipped config uses `last` today, deferring is acceptable, but I'd
   suggest at minimum adding a one-line comment next to `item_agg: last`'s handling in
   `report_series` (or in the config CHECK's validator comment) flagging this interaction
   explicitly, so the next person adding a `last` field to a workflow with shared,
   backward-movable checklist keys doesn't rediscover this the hard way. This is cheap to add
   now while the two move_stage migrations and their rationale are fresh context; it gets more
   expensive to reconstruct later.

3. **(Critique, worth considering, not blocking.)** Step 5.1's re-check of "no backward move
   has happened since drafting" runs as a separate command immediately before `db push
   --linked`, but there's still a nonzero window between that SELECT and the push where a real
   backward move via chat/agent could land on dev (the two are not run inside one transaction,
   and can't be — they're separate CLI invocations against a shared remote). The plan already
   does the right due-diligence (re-checking rather than assuming), and the risk window is
   small and the consequence (per Step 5.1's own text) is non-destructive and recoverable by a
   manual one-item correction — so this is not something to add machinery for, just worth the
   implementer being aware the re-check is a reduction of risk, not an elimination of it.

4. **(Alternative, worth considering, minor.)** D5's rejection of a tool-description addition
   to `move_stage` ("moving to a stage restores that stage's earlier values") is reasonable as
   stated (the tool result already contains the restored data, so the agent can act on it
   correctly without being told). But there's a secondary effect the plan doesn't mention:
   without that sentence, the agent has no documented basis for *proactively telling the user*
   "heads up, breakfast's numbers are different now" when a backward move surfaces old data
   that contradicts what the user just said live. This is a UX-quality gap, not a correctness
   one (D5's "no warning needed" framing is about data *loss*, which is correctly eliminated;
   it doesn't address data *surprise*). Given the UI already reload-and-displays correctly and
   this is chat-only, low priority — but worth a mental note that "no agent-facing change
   needed" and "no user-facing surprise" are not quite the same claim.

## Non-findings (specifically verified, since the task asked)

- The "never moved backward on dev" claim is based on an actual query against real data, not an
  assumption, and is re-verified pre-push.
- The SQL in Step 1 is correct as traced by hand against the actual schema/grants/RLS/indexes
  in the repo.
- The chosen design (restore-on-both-directions over clear-without-restore or
  read-side-only) is, in my independent judgment, the right call for the reasons the plan
  gives (clear-only reintroduces silent corruption via Scan Plate's additive writes;
  read-side-only can't fix the live/parked state that Scan Plate and the agent act on).
- The UX behavior-change writeup (A.1) is thorough and appropriately gated on explicit user
  sign-off before implementation.

## Summary

- 0 must-fix findings, 4 worth-considering findings (2 alternative, 1 critique+cut-this
  hybrid, 1 critique, 1 alternative — categorized above). Nothing severe enough to block the
  plan as written.
