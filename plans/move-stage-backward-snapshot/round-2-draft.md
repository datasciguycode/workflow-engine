# move_stage backward moves: snapshot the stage being left, restore the stage being entered

**Status: PLANNING ONLY. Round 2 draft. Do not implement.** Nothing here may be implemented
(no migration file in `supabase/migrations/`, no `db push`, no commit, no push) until:
1. the user has reviewed and agreed to this plan;
2. the user has explicitly answered Section A;
3. the user has been **asked again** right before implementation starts and said go (the same
   two-step confirmation the Report feature used).

Dev only: repo `/home/mmcbride/micah/claude/workflow-app`, Supabase project `workflow-engine-test`
(ref `utwyvtbzesswpoihmlic`, linked). Nothing here touches `workflow-app-prod`.

**Shape of the fix, in one paragraph.** A single migration redefines `move_stage`. It applies
the existing forward-move "clear and snapshot the shared checklist keys" logic to **backward moves
too**. Then, on every move, it **restores the destination stage's own values** from that stage's
latest snapshot. Snapshots also start listing **every** shared key, with an absent value written
as JSON `null`. `report_series` does not change. No backfill is needed, because dev has never
recorded a backward move (Section 0). No client (Razor/C#) or edge-function change is needed
(D5). The new invariant is: *for every key two sequenced stages share, `item.data` holds the
current stage's value, or nothing.* The defect is a violation of that invariant.

---

## A. Decisions the user needs to make before implementation

**How to answer.** Reply by number. "Default is fine" counts as an answer. The orchestrating
agent records the answer here ("**Answer:** …") before Step 4 runs. When asking for the
implementation go-ahead, it repeats the answer back.

1. **Accept the user-visible change in what a stage shows when you go back to it (or return to
   it)?** This is the one real UX change. The Report plan's A.2 flagged it for this follow-up.
   - **Today:** say you're at Brunch (protein 20) and tell the chat "move it back to breakfast".
     The item now sits at Breakfast, but its fields still show **Brunch's 20**. Breakfast's real
     value (say 30) is hidden: it exists only in the snapshot from the earlier forward move. If
     you then move forward again without editing, Breakfast's real 30 is overwritten by 20 in
     the history, and Brunch's 20 disappears from the item entirely. The Report then shows the
     day as 20 instead of 50. This was measured on the local stack against the shipped function
     (Section 0.3).
   - **With this fix:** going back to Breakfast shows **Breakfast's own 30**, and Brunch's 20 is
     saved. Edit Breakfast if you want, or don't. When you move forward to Brunch again, Brunch
     shows **its own 20** again (today it would come up blank). Nothing is lost either way, and
     the Report shows 50.
   - What you'll actually notice:
     - (i) After going back, the stage's checkmarks and the Details list show that stage's own
       earlier numbers, not the later stage's.
     - (ii) Returning to a stage you already filled in shows its numbers instead of blank, so
       "Complete Stage" may be available right away.
     - (iii) Scan Plate, used after going back, adds to *that* stage's own total (today it adds
       to the later stage's total and files the result under the earlier stage).
     - (iv) The chat's `move_stage` result now shows the restored values, so "go back to
       breakfast and add a banana" adds the banana to Breakfast's total, not Brunch's.
   - Only workflows whose stages share checklist keys see any difference. Today that's only
     Nutrition Tracker. The mechanic, Feature Pipeline and the test workflows share no keys and
     behave exactly as before (Step 3 check 7 proves this for the mechanic).
   - **Default: accept it.** D1 explains why the alternatives (clear without restoring, or a
     read-side-only fix) are worse.
   - **If you decline:** nothing in this plan is implemented (no migration, no script, no push).
     Restore is the core of the fix, not an add-on, so there's no "this plan minus one bullet"
     to fall back to. The orchestrating agent instead:
     1. records "declined" here and stops;
     2. asks which of the two remaining options you want, restating the cost of each from D1:
        - **(a) clear + snapshot on backward moves, no restore.** Attribution is fixed and the
          Report numbers are right if you don't edit after backing up. But the earlier stage
          comes up **blank** when you return to it, so a Scan Plate or chat "add X" after going
          back silently replaces that stage's earlier total with just X.
        - **(c-alt) refuse backward moves** between stages that share checklist keys (the chat
          gets an error). Simplest; removes the back-up-and-correct path.
        - Or **leave it as is** (the "Known limitation" stays in `PROGRESS.md`).
     3. re-plans the chosen option as a new round in this directory. Either option reuses most of
        this plan (Section 0's ground truth, D2's snapshot format, Steps 4–8's gates), but Step
        1's body and Step 3's expected values change, so they get re-drafted and re-reviewed
        rather than edited in place.
   - **Answer:** _(pending)_

**Decided in this plan; no input needed unless you disagree:**
- **No backfill and no flagging of existing snapshots.** There is nothing to correct (Section 0).
- **No client or agent change** (D5). There's no backward-move control in the UI, and nothing is
  lost by going back any more, so no warning is needed.
- **Snapshot format change** (D2). Each `cleared` snapshot now lists every shared key, with absent
  ones as `null`. This is internal: nothing outside `move_stage`/`report_series` reads it.
- The existing `scripts/report_series_dev_check.sql` gets a **one-line** update (check 2's expected
  snapshot literal) because of D2. All of its numbers are unchanged.

Also ask for explicit go-ahead at each of these points:
- implementation starting at all (the re-ask above);
- Step 6's `supabase db push --linked`, which changes the shared dev database;
- Step 8's commit, including which untracked plan directories go in it (Step 8 states the
  default and the one question to ask);
- Step 8's `git push` to `main`. Because of `deploy-pages.yml`'s `paths: web/**` filter, this
  push does **not** trigger a Pages deploy (it touches no `web/` files). It still updates the
  shared remote, so it gets its own ask. If a `web/` change were added later, the deploy gate
  would apply in full.

---

## 0. Ground truth (checked 2026-11-16, read-only against dev; rolled back on local)

### 0.1 Real dev data: nothing has been corrupted, so no backfill

Every `item.stage_changed` event on dev, classified by `sequence_order` direction:

```bash
supabase db query --linked "select w.name,
  count(*) filter (where ts.sequence_order < fs.sequence_order) back,
  count(*) filter (where ts.sequence_order > fs.sequence_order) fwd,
  count(*) filter (where ts.sequence_order is null or fs.sequence_order is null
                     or ts.sequence_order = fs.sequence_order) other,
  count(*) filter (where e.data is not null) with_data,
  max(e.created_at)::text last_move
from public.item_events e
join public.items i on i.id = e.item_id
join public.workflows w on w.id = i.workflow_id
left join public.stages fs on fs.id = e.from_stage_id
left join public.stages ts on ts.id = e.to_stage_id
where e.event_type = 'item.stage_changed'
group by w.name" -o table
```

| workflow | back | fwd | other | with_data | last move |
|---|---|---|---|---|---|
| Nutrition Tracker | **0** | 6 | 0 | **0** | 2026-11-15 22:25 UTC |
| Joe's Auto Repair | **0** | 9 | 1 (→ `closed`, null seq) | 0 | 2026-11-15 01:36 UTC |

- **No item on dev has ever moved backward.** So the defect has never fired on real data, and no
  item is "parked" at an earlier stage holding a later stage's values. (An item like that would
  have been the one case a go-forward fix can't repair, because its next forward move would still
  snapshot the carried-over values.)
- **No `cleared` snapshot has ever been written on dev** (`with_data = 0`). All six Nutrition
  forward moves predate the `20261115000000` push. So there's no data in the old snapshot format
  that the new one would mix with (D2).
- Even if there were bad snapshots, `item_events` is append-only by RLS (no UPDATE/DELETE
  policy, `20261012035437`), so a correction would have to be a privileged migration. That
  question doesn't arise.
- **Conclusion: purely a go-forward fix.** Step 5.1 re-runs this query right before the push. If
  a backward move happens on dev before the fix lands, the plan says what to do.

### 0.2 Live function = repo file; schema facts relied on

- The live `public.move_stage` source on dev has the same md5 (`e8ac36d9…`, 2193 chars) as the
  body of `supabase/migrations/20261115000000_move_stage_records_cleared_values.sql`, so the file
  is the live behaviour. The applied migrations end at `20261115010000`.
- `move_stage`, `update_data`, `report_series` are `security invoker`, `search_path=""`.
  `authenticated` has `select, insert` on `item_events` (`20261101000000`). So the new restore
  query, which reads `item_events` under invoker rights, runs under the same RLS
  (`item_events_select`) that `report_series` already relies on.
- The index `item_events_item_seq (item_id, seq)` exists (`20261012154028`), so the per-move
  restore lookup is an indexed scan of one item's events.
- `update_data` deletes a key when the patch value is JSON `null` (`20261016130000`). So "a stage's
  value was deleted" is a real state, and D2 has to handle it.
- `item.data` also holds non-checklist keys (`description`, `eaten` on real Nutrition items). These
  are never cleared, snapshotted or restored. That's unchanged.
- Stage layout on dev: Nutrition has 5 stages (`sequence_order` 1–5), all with the same six-key
  checklist, and `enforce_stage_order = false`. The mechanic's stages share **no** checklist keys,
  and `closed` has a null `sequence_order`. Feature Pipeline (`enforce_stage_order = true`) and
  the two test workflows have no checklists. No workflow has two stages with the same
  `sequence_order`.

### 0.3 The defect, reproduced (local stack, shipped migrations, rolled back)

Breakfast 30/10/5 (protein/carbs/fat), forward to Brunch, Brunch 20/20/10, back to Breakfast,
forward to Brunch without editing. With the **shipped** `move_stage`:

| moment | report_series day | truth |
|---|---|---|
| while parked back at Breakfast | protein 20, carbs 20, fat 10, calories 250 | 50 / 30 / 15, 455 |
| after re-departure | re-departure snapshot `{"cleared": {"protein_g": 20, "carbs_g": 20, "fat_g": 10}}` (Brunch's values filed as Breakfast's); Brunch's `item.data` is `{}`; report 20/20/10, 250 | 50 / 30 / 15, 455 |

So the defect is worse than "Breakfast is misattributed": **Breakfast's real value is overwritten
and Brunch's is erased**. The day under-reports by both meals' difference. And the transient
"parked" state already reports wrong numbers before any forward move. With the proposed function,
the same sequence reports 50/30/15, 455 at both moments (Step 3, check 2).

### 0.4 How backward moves happen today

The web UI has no backward-move control. `WorkflowDetail.razor`'s only move is "Complete Stage"
→ `NextStage` (forward). Backward moves come only from the agent's `move_stage` tool
(`supabase/functions/agent-loop/index.ts`), the MCP server's `move_stage` tool
(`supabase/functions/mcp-server/index.ts`), or direct RPC. All of these go through
`public.move_stage`, so a database-layer fix covers every path.

---

## 1. What gets built

1. **Migration `20261116000000_move_stage_restores_stage_values.sql`**: `create or replace
   function public.move_stage`. The same signature, so existing grants and the PostgREST schema
   are unaffected. Three changes, all inside the shared-key path:
   - shared keys are computed for any move between two **different** `sequence_order` values
     (forward, as today, **and backward**);
   - the snapshot lists **every** shared key, with absent values as JSON `null`;
   - after clearing, each shared key is **restored** from the destination stage's latest snapshot
     that lists it.
2. **`scripts/report_series_dev_check.sql`**: check 2's expected snapshot literal gains the four
   null keys. Nothing else changes.
3. **New `scripts/move_stage_backward_dev_check.sql`**: a self-rolling-back `DO` block proving the
   backward-then-forward scenario and its edge cases.
4. **`PROGRESS.md`: not edited by this plan.** Per `CLAUDE.md`, it's updated only at a
   user-invoked milestone. Step 9 lists what to carry into it then: remove the "Known limitation"
   section and its Outstanding bullet; add a one-line "backward moves save and restore per-stage
   values" note under the Report entry; add `20261116000000` to the dev-only/not-yet-ported list.

`report_series`, the web app, `agent-loop` and `mcp-server` are **not** changed. (The new
migration's header comment documents one `report_series` consequence, the `item_agg: last`
note in Section 5. That's a comment in the new file only, not a `report_series` change.)

## 2. Decisions

### D1. Restore-on-move in `move_stage` (a write-side fix), not clear-only and not read-side

The root cause is that `item.data` is one flat namespace, and only forward moves keep it
consistent with "the current stage's values". The fix makes every sequenced move keep it
consistent: **save what you're leaving, load what you're entering.** Then every snapshot is
correctly attributed, because when a stage is left its shared keys are, by construction, that
stage's.

The brief's starting ideas, and why they lose:

- **(a) Clear and snapshot on backward moves, without restoring.** This fixes the attribution
  (Brunch's 20 gets snapshotted as Brunch's). But the earlier stage comes up **blank**, which is
  worse than today for the main reason anyone goes back: to fix or add to that stage.
  - Scan Plate adds to the live value (`ExistingPlus` in `WorkflowDetail.razor`). After a blank
    restore, a "forgot the banana" scan writes *banana only* as Breakfast's total. The live value
    then outranks Breakfast's real snapshot in `report_series`, so Breakfast's earlier food
    silently disappears.
  - The same happens with the chat ("add 5g protein to breakfast" reads 0).
  - So (a) trades one silent corruption for another. Restore is what makes (a) safe. The plan is
    (a) + restore.
- **(b) Leave `move_stage` alone and disambiguate in `report_series`.** A reader could replay
  `data_changed` events to decide whether the value present at a re-departure was edited after
  the backward hop. But:
  - It cannot fix the **live** state. While parked, the UI, the agent and Scan Plate all see the
    later stage's values under the earlier stage's name. An additive scan in that state mixes
    the two stages' values into one number that no reader can split. "Edited since the hop" is
    exactly the case (b) would have to trust, and it's the corrupted one.
  - It reintroduces the event-replay approach the Report plan's D1 rejected (it re-interprets
    history, and is complex).
  - It also leaves the later stage's value un-snapshotted, so it would have to be recovered from
    the last `data_changed` before the backward move as well.
- **(c-alt) Forbid backward moves when stages share keys.** Simple, but it removes the
  back-up-and-correct path that the Report feature's own check 3 exercises and that the chat
  supports. Rejected.
- **(c-alt) Per-stage namespaced storage** (`data.stages[...]`, or a values table). Already
  rejected in the Report plan's D1: it breaks the shared-checklist design and every reader.
  Restore gets the same per-stage semantics without changing storage.

**Direction rule.** Shared keys are computed when both `sequence_order`s are non-null and
**differ**. The previous rule was `to > from`.
- Same-stage moves and moves to or from an unsequenced stage (the mechanic's `closed`) still
  touch nothing, as today.
- Equal-but-different `sequence_order` stages don't exist on dev. They'd be treated as "touch
  nothing", the same as today. Extending the rule to them is out of scope.

### D2. Snapshots list every shared key; JSON `null` means "this stage had no value"

Today a snapshot lists only the keys that were *present*. With restore, that's a correctness bug.
Example: Brunch had fat 10 and was snapshotted. You return to Brunch and delete fat (an
`update_data` null patch). Then you leave again: the new snapshot omits `fat_g`. On the next
return, the per-key "latest snapshot that lists it" rule would **resurrect fat 10**. (Step 3
check 4 fails exactly that way without D2.) `report_series` has the same blind spot today: it
would keep counting the deleted 10.

Listing every shared key, absent ones as `null`, fixes both. No `report_series` change is needed:
- its `e.data -> 'cleared' ? f.key` matches a `null` entry;
- `private.jsonb_numeric('null')` is SQL NULL;
- the null segment wins its stage's dedupe;
- `sum`/`avg`/`last`/`count` all ignore NULL.

This is verified by Step 3 check 4: fat 5, not 15.

Effects:
- Workflows with no shared keys still write `data = null` (zero rows → `jsonb_object_agg`
  returns null).
- A Nutrition move with nothing logged now writes six nulls instead of `null` data. That's
  harmless: nothing else reads `stage_changed.data` (Report plan 0.1).
- Snapshots in the old presence-only format, if any get written before the push, are read
  correctly: a key they don't list is simply not restored or counted.

*Rejected:* restoring the destination's whole **latest single snapshot** instead of per key. With
the old format, it can't tell "absent" from "not shared on that move" (partial checklist
overlap). It also diverges from `report_series`'s per-(item, stage, key) rule, so the stage view
and the report could disagree about a stage's value.

### D3. Restore uses exactly `report_series`'s per-(item, from_stage, key) "latest by `seq`" rule

So "what a stage shows when you return to it" and "what the Report counts for that stage" are the
same number by construction. When the item is at a stage, its live value (restored, then possibly
edited) outranks every snapshot of that stage in `report_series` (seq = ∞), as it does today. When
it leaves, the new snapshot becomes the latest.

### D4. `report_series` is unchanged

Under the new invariant, `report_series`'s existing assumptions become true:
- the live value belongs to the current stage;
- each snapshot belongs to its `from_stage_id`, whatever direction the move went.

Backward-move snapshots are picked up with no change (keyed on `from_stage_id`, ranked by
`seq`). The local runs (Section 0.3; Step 4) confirm the right numbers come out of the shipped
`report_series` body.

Its header comment says snapshots come from "the most recent forward move OUT of that stage".
After this migration that wording is stale (it's now any sequenced move). It's left as is:
redefining the function only to change a comment isn't worth it, and the new migration's comment
documents the change.

### D5. No client, agent or MCP change

- **UI.** No control moves an item backward. After every move the page reloads items from the
  server: `DoneMoveToNextStage` does, and so does `Send` (which covers chat-driven moves). Stage
  cards show values only for the current stage (the 2026-11-13 gating). Scan Plate reads the
  reloaded `_selectedItem.Data`, so after a chat-driven backward move it automatically sees the
  restored value.
- **Warning.** A "you're about to lose data" warning on backing up has nothing to warn about any
  more.
- **Agent.** `move_stage` returns the updated `items` row. The agent's tool result therefore
  already contains the restored values, so it computes "add X to breakfast" from Breakfast's
  total. An extra sentence in the tool description ("moving to a stage restores that stage's
  earlier values") was considered and left out. The tool result already says it, and an
  edge-function redeploy would add a gate for no correctness gain. If the user wants it, it's a
  separate small change.

### D6. One migration, body otherwise byte-identical to `20261115000000`

The new function body differs from `20261115000000`'s in exactly five regions, each marked
`-- NEW` or `-- CHANGED` in the file:
1. the `v_restored` declaration (one line, NEW);
2. the shared-keys `if` condition (`>` → `<>`, CHANGED);
3. the `v_cleared` query (now every shared key with `null` for absent ones, and no `where`
   filter; CHANGED);
4. the restore query (a ~14-line `select … into v_restored`, NEW; the only substantial addition);
5. the `update`'s `data =` line (now `|| coalesce(v_restored, …)`, CHANGED).

The diff also shows the old file's `-- NEW`/`-- CHANGED` comment tails dropped from the
`v_cleared` declaration and the `insert` line, since those marked the previous migration's edits.
Nothing else differs. In particular the `enforce_stage_order` block is untouched;
`20261016130000` once dropped it silently. Step 5.3's `diff` checks exactly this list
mechanically, the same way the Report plan's Step 4.1 did. (The header comment above `create or
replace` is new prose and is outside the diffed range.)

---

## 3. Steps

### Step 1. Migration: `supabase/migrations/20261116000000_move_stage_restores_stage_values.sql`

The literal file. It was validated as-is on the local stack (Section 0.3, Step 4):

```sql
-- move_stage: every move between two sequenced stages saves the departing stage's shared-field
-- values and restores the arriving stage's own (2026-11-16). Fixes the residual limitation
-- 20261115000000 left (plans/move-stage-backward-snapshot/): a backward move used to clear and
-- record nothing, so item.data kept the later stage's values while the item sat at the earlier
-- stage -- shown under the earlier stage's name, added to by Scan Plate as if they were that
-- stage's, and, on the next forward move, snapshotted as that stage's value, silently replacing
-- its real snapshot (report_series then reported the later stage's numbers for it).
-- Invariant after this migration: for every key two sequenced stages share, item.data holds the
-- CURRENT stage's value or nothing. Three changes, all inside the shared-key path, so a workflow
-- whose stages share no keys (the mechanic, Feature Pipeline) behaves exactly as before:
--   1. Shared keys are computed for any move between two different sequence_order values, not only
--      forward ones. Moves involving an unsequenced stage (null sequence_order, e.g. the mechanic's
--      "closed") or between equal sequence_orders still touch nothing, as before.
--   2. The snapshot lists EVERY shared key, an absent one as JSON null ("this stage had no value"),
--      not only the keys present. Without that, a value deleted at a stage (update_data with null)
--      could be restored from an older snapshot. report_series (20261115010000) needs no change: a
--      JSON-null snapshot is a segment whose value is null, which it already ignores in sums/avgs
--      and which correctly wins its stage's dedupe over an older non-null snapshot.
--   3. After clearing, each shared key is restored from the arriving stage's latest snapshot that
--      lists it (latest per key by item_events.seq: the same per-(item, from_stage, key) rule
--      report_series uses, so what the stage shows and what the report counts for it agree).
--      A JSON-null or missing snapshot restores nothing. A stage never visited restores nothing,
--      so a first-time forward move behaves exactly as before.
-- No backfill: as of 2026-11-16 dev had never recorded a backward move or a cleared snapshot, so
-- nothing was misattributed. Snapshots written before this migration (presence-only format) are
-- still read correctly: a key they don't list just isn't restored.
-- Note for report_series (20261115010000), item_agg "last": it ranks a stage's values by
-- item_events.seq with the live value newest. Now that a backward move restores the arriving
-- stage's own value, an item parked back at an earlier stage reports THAT stage's value as "last"
-- for a shared checklist key -- i.e. whichever stage the item currently sits at, not the most
-- recently entered value. No shipped config uses "last" on a shared key; if one ever does, it
-- probably wants to order by stages.sequence_order instead.
-- Body is otherwise identical to 20261115000000.

create or replace function public.move_stage(p_item_id uuid, p_to_stage_id uuid)
returns public.items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item public.items;
  v_from_stage uuid;
  v_enforce boolean;
  v_from_seq integer;
  v_to_seq integer;
  v_from_checklist jsonb;
  v_to_checklist jsonb;
  v_shared_keys text[];
  v_cleared jsonb;
  v_restored jsonb;  -- NEW
begin
  select * into v_item from public.items where id = p_item_id for update;
  if not found then
    raise exception 'item not found';
  end if;

  v_from_stage := v_item.stage_id;

  select enforce_stage_order into v_enforce
  from public.workflows where id = v_item.workflow_id;

  select sequence_order, checklist into v_from_seq, v_from_checklist
  from public.stages where id = v_from_stage;
  select sequence_order, checklist into v_to_seq, v_to_checklist
  from public.stages where id = p_to_stage_id;

  if v_enforce then
    if v_from_seq is not null and v_to_seq is not null
       and v_to_seq > v_from_seq
       and v_to_seq != v_from_seq + 1 then
      raise exception 'forward skip from stage % (seq %) to stage % (seq %) is not allowed when enforce_stage_order is true',
        v_from_stage, v_from_seq, p_to_stage_id, v_to_seq;
    end if;
  end if;

  if v_from_seq is not null and v_to_seq is not null and v_to_seq <> v_from_seq then  -- CHANGED: was v_to_seq > v_from_seq
    select array_agg(elem) into v_shared_keys
    from jsonb_array_elements_text(coalesce(v_to_checklist, '[]'::jsonb)) elem
    where coalesce(v_from_checklist, '[]'::jsonb) ? elem;
  end if;

  -- CHANGED: every shared key, an absent one as JSON null (v_item is still the pre-update row).
  -- No shared keys -> zero rows -> jsonb_object_agg returns null -> event data stays null.
  select jsonb_object_agg(k, coalesce(v_item.data -> k, 'null'::jsonb)) into v_cleared
  from unnest(coalesce(v_shared_keys, array[]::text[])) as k;

  -- NEW: the arriving stage's own values, from the last time the item left it. Per key, the
  -- latest snapshot (by seq) out of p_to_stage_id that lists the key; JSON null = no value.
  select jsonb_object_agg(r.k, r.v) into v_restored
  from (
    select distinct on (s.k) s.k, e.data -> 'cleared' -> s.k as v
    from unnest(coalesce(v_shared_keys, array[]::text[])) as s(k)
    join public.item_events e
      on e.item_id = p_item_id
     and e.event_type = 'item.stage_changed'
     and e.from_stage_id = p_to_stage_id
     and e.data -> 'cleared' ? s.k
    order by s.k, e.seq desc
  ) r
  where jsonb_typeof(r.v) <> 'null';

  update public.items
  set stage_id = p_to_stage_id,
      data = (data - coalesce(v_shared_keys, array[]::text[])) || coalesce(v_restored, '{}'::jsonb),  -- CHANGED
      updated_at = now()
  where id = p_item_id
  returning * into v_item;

  insert into public.item_events (item_id, event_type, from_stage_id, to_stage_id, stage_id, data)
  values (p_item_id, 'item.stage_changed', v_from_stage, p_to_stage_id, p_to_stage_id,
          case when v_cleared is not null then jsonb_build_object('cleared', v_cleared) end);

  return v_item;
end;
$$;
```

Notes:
- `create or replace` keeps the existing `revoke all … from public` / `grant execute … to
  authenticated` (from `20261012035437`). No re-grant needed; prior redefinitions didn't either.
- Order inside the function: capture (`v_cleared`) from the pre-update row, compute `v_restored`,
  then `update`, then `insert` the event. The restore lookup reads events from `p_to_stage_id`.
  The event being inserted is from `v_from_stage`, so the order is safe even for skips.
- `(data - keys) || restored`: `-` runs first (explicit parentheses). A restored key can't
  collide with a non-shared key, because restored keys ⊆ shared keys.
- The item row is locked `for update` at the top, and `update_data` takes the same lock. So no
  concurrent `update_data` or `move_stage` on the same item can interleave between the restore
  lookup and the write.

### Step 2. `scripts/report_series_dev_check.sql`: one-line update

Check 2 asserts the exact snapshot from a forward move. Under D2 it now lists all six shared keys.
The only change:

```diff
-  if v_ev is distinct from '{"cleared": {"protein_g": 30, "weight_lbs": 180}}'::jsonb then
+  if v_ev is distinct from '{"cleared": {"protein_g": 30, "weight_lbs": 180, "carbs_g": null, "fat_g": null, "fiber_g": null, "sugar_g": null}}'::jsonb then
```

Every other check (3: back-up-and-correct = 55; 4: skip = 60; 6: the four weekly numbers; 10:
`last`) passes **unchanged** with the new function. They now pass for the right reason: in check
3, the backward move restores Breakfast's 30 before the correction to 35, rather than the user
overwriting a carried-over Brunch 20.

### Step 3. New `scripts/move_stage_backward_dev_check.sql`

Run it with `supabase db query --linked -f scripts/move_stage_backward_dev_check.sql`.
- **Success:** an error message starting with `PASS`.
- **Failure:** anything else (`FAIL …`, `SETUP …`, or any other error).
- Nothing persists either way, and it's safe to re-run.

The test day is back-dated to Mon 2026-02-02. That's isolated from the real data (the SETUP
guard) and from `report_series_dev_check.sql`'s 2026-01-05 week. All three macros are logged at
every reported stage, so the shipped `item_requires` never drops the day, and no config strip or
restore is needed.

```sql
-- move_stage backward-move checks (20261116000000). ALWAYS ends in an exception so every write
-- below is rolled back; success is an error message beginning 'PASS'. Safe to re-run.
-- The test day is back-dated to Mon 2026-02-02 (America/Chicago), which predates the Nutrition
-- Tracker workflow, so real items never mix into the asserted numbers. It logs all three macros at
-- every stage it reports, so the shipped item_requires never drops it (no config swap needed).
do $$
declare
  v_tz  text := 'America/Chicago';
  v_day date := '2026-02-02';
  v_wf uuid; v_uid uuid;
  v_b uuid; v_br uuid; v_l uuid;
  d uuid;
  v_data jsonb; v_ev jsonb; v_fv jsonb;
  v_mech uuid; v_mid uuid; v_m_init uuid; v_m_next uuid; v_mdata jsonb;
begin
  ---------------------------------------------------------------- setup (as the CLI's role)
  select id into v_wf from public.workflows where name = 'Nutrition Tracker';
  select am.user_id into v_uid
  from public.account_members am
  join public.workflows w on w.account_id = am.account_id
  where w.id = v_wf and am.role = 'owner'
  order by am.created_at
  limit 1;
  if v_wf is null or v_uid is null then raise exception 'SETUP: workflow or owner not found'; end if;
  if (select report_config from public.workflows where id = v_wf) is null then
    raise exception 'SETUP: Nutrition Tracker has no report_config';
  end if;
  if exists (select 1 from public.items where workflow_id = v_wf and created_at < '2026-11-01') then
    raise exception 'SETUP: real Nutrition items exist before 2026-11-01; test day is not isolated';
  end if;
  select id into v_b  from public.stages where workflow_id = v_wf and title = 'breakfast';
  select id into v_br from public.stages where workflow_id = v_wf and title = 'brunch';
  select id into v_l  from public.stages where workflow_id = v_wf and title = 'lunch';
  if v_b is null or v_br is null or v_l is null then raise exception 'SETUP: meal stages not found'; end if;

  ---------------------------------------------------------------- become the real user; create the test day
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
  -- "description" is not a checklist key: every item.data assertion below includes it, proving
  -- non-shared keys ride through every move untouched.
  select id into d from public.create_item(v_wf, '{"description": "test day"}'::jsonb);
  reset role;
  update public.items set created_at = '2026-02-02 18:00+00' where id = d;
  set local role authenticated;

  ---------------------------------------------------------------- 1. breakfast, forward, brunch
  perform public.update_data(d, '{"protein_g": 30, "carbs_g": 10, "fat_g": 5}');
  perform public.move_stage(d, v_br);
  select data into v_ev from public.item_events
  where item_id = d and event_type = 'item.stage_changed' order by seq desc limit 1;
  -- containment only here, so that against the PRE-fix function the first failure is the defect
  -- itself (check 2); the full all-keys-with-nulls format is asserted from check 2 on
  if not coalesce(v_ev -> 'cleared' @> '{"protein_g": 30, "carbs_g": 10, "fat_g": 5}'::jsonb, false) then
    raise exception 'FAIL forward snapshot: % (want breakfast 30/10/5)', v_ev;
  end if;
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day"}'::jsonb then
    raise exception 'FAIL first visit: brunch should start empty, got %', v_data;
  end if;
  perform public.update_data(d, '{"protein_g": 20, "carbs_g": 20, "fat_g": 10}');

  ---------------------------------------------------------------- 2. THE DEFECT: back, then forward without editing
  perform public.move_stage(d, v_b);
  select data into v_ev from public.item_events
  where item_id = d and event_type = 'item.stage_changed' order by seq desc limit 1;
  if v_ev is distinct from '{"cleared": {"protein_g": 20, "carbs_g": 20, "fat_g": 10, "fiber_g": null, "sugar_g": null, "weight_lbs": null}}'::jsonb then
    raise exception 'FAIL backward snapshot: % (want brunch''s 20/20/10; null = old behaviour, nothing recorded)', v_ev;
  end if;
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day", "protein_g": 30, "carbs_g": 10, "fat_g": 5}'::jsonb then
    raise exception 'FAIL backward restore: % (want breakfast''s own 30/10/5; 20/20/10 = old behaviour)', v_data;
  end if;
  select field_values into v_fv from public.report_series(v_wf, v_day, v_day, v_tz);
  if v_fv is distinct from '{"protein_g": 50, "carbs_g": 30, "fat_g": 15, "calories": 455}'::jsonb then
    raise exception 'FAIL report while backed up: % (want 50/30/15, 455; 20/20/10, 250 = old behaviour)', v_fv;
  end if;

  perform public.move_stage(d, v_br);
  select data into v_ev from public.item_events
  where item_id = d and event_type = 'item.stage_changed' order by seq desc limit 1;
  if v_ev is distinct from '{"cleared": {"protein_g": 30, "carbs_g": 10, "fat_g": 5, "fiber_g": null, "sugar_g": null, "weight_lbs": null}}'::jsonb then
    raise exception 'FAIL re-departure snapshot: % (want breakfast''s 30/10/5; 20/20/10 = THE DEFECT)', v_ev;
  end if;
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day", "protein_g": 20, "carbs_g": 20, "fat_g": 10}'::jsonb then
    raise exception 'FAIL forward restore: % (want brunch''s 20/20/10 back; empty = old behaviour)', v_data;
  end if;
  select field_values into v_fv from public.report_series(v_wf, v_day, v_day, v_tz);
  if v_fv is distinct from '{"protein_g": 50, "carbs_g": 30, "fat_g": 15, "calories": 455}'::jsonb then
    raise exception 'FAIL report after back-and-forward: % (want 50/30/15, 455; 20/20/10, 250 = THE DEFECT)', v_fv;
  end if;

  ---------------------------------------------------------------- 3. back up and add, Scan Plate style (read live, add, write)
  perform public.move_stage(d, v_b);
  select data into v_data from public.items where id = d;
  perform public.update_data(d, jsonb_build_object('protein_g', (v_data ->> 'protein_g')::numeric + 5));
  perform public.move_stage(d, v_br);
  select field_values into v_fv from public.report_series(v_wf, v_day, v_day, v_tz);
  if v_fv is distinct from '{"protein_g": 55, "carbs_g": 30, "fat_g": 15, "calories": 475}'::jsonb then
    raise exception 'FAIL add while backed up: % (want breakfast 35 + brunch 20 = 55 protein, 475)', v_fv;
  end if;

  ---------------------------------------------------------------- 4. a deleted value is not resurrected
  perform public.update_data(d, '{"fat_g": null}');      -- delete brunch's fat
  perform public.move_stage(d, v_b);
  perform public.move_stage(d, v_br);
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day", "protein_g": 20, "carbs_g": 20}'::jsonb then
    raise exception 'FAIL delete: % (want brunch without fat_g; fat_g 10 = an older snapshot resurrected)', v_data;
  end if;
  select field_values into v_fv from public.report_series(v_wf, v_day, v_day, v_tz);
  if v_fv is distinct from '{"protein_g": 55, "carbs_g": 30, "fat_g": 5, "calories": 385}'::jsonb then
    raise exception 'FAIL delete report: % (want fat 5 = breakfast only; 15 = deleted brunch fat still counted)', v_fv;
  end if;

  ---------------------------------------------------------------- 5. two stages back, then a forward skip
  perform public.move_stage(d, v_l);
  perform public.update_data(d, '{"protein_g": 15, "carbs_g": 5, "fat_g": 5}');
  perform public.move_stage(d, v_b);                     -- lunch -> breakfast
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day", "protein_g": 35, "carbs_g": 10, "fat_g": 5}'::jsonb then
    raise exception 'FAIL two back: % (want breakfast 35/10/5)', v_data;
  end if;
  perform public.move_stage(d, v_l);                     -- breakfast -> lunch (skip)
  select data into v_data from public.items where id = d;
  if v_data is distinct from '{"description": "test day", "protein_g": 15, "carbs_g": 5, "fat_g": 5}'::jsonb then
    raise exception 'FAIL skip restore: % (want lunch 15/5/5)', v_data;
  end if;
  select field_values into v_fv from public.report_series(v_wf, v_day, v_day, v_tz);
  if v_fv is distinct from '{"protein_g": 70, "carbs_g": 35, "fat_g": 10, "calories": 510}'::jsonb then
    raise exception 'FAIL skip report: % (want 35+20+15 / 10+20+5 / 5+0+5, 510)', v_fv;
  end if;

  ---------------------------------------------------------------- 6. same-stage move: nothing cleared or recorded
  perform public.move_stage(d, v_l);
  select data into v_ev from public.item_events
  where item_id = d and event_type = 'item.stage_changed' order by seq desc limit 1;
  select data into v_data from public.items where id = d;
  if v_ev is not null
     or v_data is distinct from '{"description": "test day", "protein_g": 15, "carbs_g": 5, "fat_g": 5}'::jsonb then
    raise exception 'FAIL same-stage: event % data %', v_ev, v_data;
  end if;

  ---------------------------------------------------------------- 7. mechanic (no shared keys): backward move unchanged
  select id into v_mech from public.workflows where name = 'Joe''s Auto Repair';
  select id into v_mid from public.create_item(v_mech, '{"customer": "test"}'::jsonb);
  select stage_id into v_m_init from public.items where id = v_mid;
  select s.id into v_m_next from public.stages s
  where s.workflow_id = v_mech
    and s.sequence_order > (select s0.sequence_order from public.stages s0 where s0.id = v_m_init)
  order by s.sequence_order limit 1;
  perform public.move_stage(v_mid, v_m_next);
  perform public.update_data(v_mid, '{"scheduled_at": "2026-02-03T09:00"}');
  perform public.move_stage(v_mid, v_m_init);
  select data into v_mdata from public.items where id = v_mid;
  if v_mdata is distinct from '{"customer": "test", "scheduled_at": "2026-02-03T09:00"}'::jsonb
     or exists (select 1 from public.item_events where item_id = v_mid
                and event_type = 'item.stage_changed' and data is not null) then
    raise exception 'FAIL mechanic: data % or a stage_changed event has data', v_mdata;
  end if;

  raise exception 'PASS (all rolled back): snapshots list every shared key (absent = null), backward snapshot + restore ok, report 455 while backed up and after back-and-forward (defect = 250), Scan-Plate-style add 55, deleted value not resurrected, two-back + skip ok, same-stage no-op, mechanic unchanged';
end;
$$;
```

Expected numbers (one day; protein / carbs / fat → calories = 4p + 4c + 9f):

| after check | breakfast | brunch | lunch | day total | defect value named in the FAIL text |
|---|---|---|---|---|---|
| 2 (parked at breakfast, then forward unedited) | 30/10/5 | 20/20/10 | — | 50/30/15 → 455 | 20/20/10 → 250 |
| 3 (back, +5 protein from the live value, forward) | 35/10/5 | 20/20/10 | — | 55/30/15 → 475 | |
| 4 (brunch fat deleted, back, forward) | 35/10/5 | 20/20/null | — | 55/30/5 → 385 | fat 15 / `fat_g: 10` resurrected |
| 5 (lunch 15/5/5, back two stages, skip forward to lunch) | 35/10/5 | 20/20/null | 15/5/5 | 70/35/10 → 510 | |

- Check 6: a same-stage move writes `data = null` and changes nothing (today's behaviour).
- Check 7: a mechanic backward move leaves `item.data` untouched, and every `stage_changed.data`
  is null (today's behaviour, now under the widened direction rule).
- Check 1 uses **containment** on purpose. Against the *current* (unfixed) dev function, the
  script's first failure is then the defect itself: `FAIL backward snapshot: <NULL>`, not a
  format nit. That makes the script usable as a pre-push demonstration (Step 5.2).

### Step 4. Local gate (rolled back). Must pass before `db push` is even asked about

Pre-conditions: Section A.1 has a recorded answer, and the two script files exist in `scripts/`
and the migration in `supabase/migrations/`. Those files are just local working-tree files at
this point: no commit.

The local stack is at `20261016130000`. As in the Report plan (its Section 0.2), every later
migration except `20261023120000` (its `chat_messages` table already exists locally) applies
inside one transaction. Each run is `begin; <migrations>; <check>; rollback;` with
`ON_ERROR_STOP`. The `DO` block's final `raise` ends the session, so nothing persists.

```bash
cd /home/mmcbride/micah/claude/workflow-app
pre() {
  echo "begin;"
  for f in $(ls supabase/migrations/*.sql | awk -F/ '{print $NF}' \
             | awk 'substr($0,1,14) > "20261016130000" && $0 !~ /^20261023120000/'); do
    cat "supabase/migrations/$f"; echo
  done
}
run() { docker exec -i supabase_db_workflow-app psql -U postgres -v ON_ERROR_STOP=1 -q 2>&1 | grep ERROR; }

# 4a. new check, WITH the fix (pre() includes 20261116000000 once it's in supabase/migrations/)
{ pre; cat scripts/move_stage_backward_dev_check.sql; echo "rollback;"; } | run
# expect: ERROR:  PASS (all rolled back): ...

# 4b. updated Report regression check, WITH the fix
{ pre; cat scripts/report_series_dev_check.sql; echo "rollback;"; } | run
# expect: ERROR:  PASS (all rolled back): jsonb_numeric ok, 33 bad configs rejected, ...

# 4c. sensitivity: new check WITHOUT the fix must fail on the defect
{ echo "begin;"; for f in $(ls supabase/migrations/*.sql | awk -F/ '{print $NF}' \
    | awk 'substr($0,1,14) > "20261016130000" && substr($0,1,14) < "20261116000000" && $0 !~ /^20261023120000/'); do
    cat "supabase/migrations/$f"; echo; done
  cat scripts/move_stage_backward_dev_check.sql; echo "rollback;"; } | run
# expect: ERROR:  FAIL backward snapshot: <NULL> (want brunch's 20/20/10; null = old behaviour, nothing recorded)
```

All three must print what's shown. Afterwards, confirm the local stack wasn't changed: `select
max(version) from supabase_migrations.schema_migrations` is still `20261016130000`, and
`report_series` does not exist locally.

**Already done once while drafting (2026-11-16)**, from scratchpad copies identical to Steps 1–3
(apart from the migration header's `item_agg: last` comment, added in round 2; it's a SQL
comment, so it can't change any result):
- 4a `PASS`;
- 4b `PASS` (33 rejected, enforce: forward skip rejected);
- 4c `FAIL backward snapshot: <NULL>`;
- the *unmodified* Report script against the fix failed only at check 2's snapshot literal (the
  reason for Step 2);
- the unmodified Report script without the fix still passes (baseline).

The local stack stayed at `20261016130000`. The implementer must re-run 4a–4c from the real
files, because transcription is exactly what this gate catches.

### Step 5. Dev pre-push checks (read-only, or rolled back)

**5.1 Re-check ground truth.** Re-run Section 0.1's query. Then:

```bash
supabase db query --linked "select left(i.id::text, 8) item, w.name, fs.title from_stage, ts.title to_stage, e.created_at::text
from public.items i
join public.workflows w on w.id = i.workflow_id
join lateral (select * from public.item_events e where e.item_id = i.id and e.event_type = 'item.stage_changed'
              order by e.seq desc limit 1) e on true
join public.stages fs on fs.id = e.from_stage_id
join public.stages ts on ts.id = e.to_stage_id
where ts.sequence_order < fs.sequence_order" -o table
```

This lists items whose **latest** move was backward: items parked at an earlier stage holding a
later stage's values.
- **Expected: zero rows, and `back = 0` in 0.1.** If so, proceed.
- If any backward move has happened since 2026-11-16, **stop and report it to the user** before
  the push. A parked item's next forward move would still snapshot carried-over values, even
  after the fix, because the fix can't know what was carried. The simplest remedy is per item
  and needs the user's call: re-enter that stage's values before moving on, or accept that day's
  numbers as approximate. This plan doesn't pre-decide it, because it's expected not to arise.
- Forward moves since 2026-11-16 are fine. They write old-format snapshots, which D2 reads
  correctly.
- This re-check **narrows** the window rather than closing it: it and Step 6's push are separate
  CLI calls, not one transaction, so a backward move could still land in between. Run Step 6
  promptly after 5.1 (5.2–5.4 are quick). In practice the window is minutes and backward moves
  only come from the chat or MCP. Step 7.3's before/after comparison would surface a stray
  move, and the remedy is the same per-item one above.

**5.2 Demonstrate the defect on dev (rolled back).**

```bash
supabase db query --linked -f scripts/move_stage_backward_dev_check.sql
```

Expect `FAIL backward snapshot: <NULL> …`. This shows the live dev function has the defect and
that the script detects it. Any `SETUP …` error means fix the environment first.

**5.3 Mechanical diff and dry run.**

```bash
cd /home/mmcbride/micah/claude/workflow-app
diff <(sed -n '/create or replace function/,$p' supabase/migrations/20261115000000_move_stage_records_cleared_values.sql) \
     <(sed -n '/create or replace function/,$p' supabase/migrations/20261116000000_move_stage_restores_stage_values.sql)
# expect ONLY: the v_restored declaration; the shared-keys "if" (> -> <>); the v_cleared block
# (comment + jsonb_object_agg with coalesce(..., 'null'), no "where" filter); the NEW restore block;
# the update's data line; and the dropped "-- NEW"/"-- CHANGED" comment tails on the
# v_cleared declaration and the insert line.
supabase db push --linked --dry-run   # expect exactly one file: 20261116000000_move_stage_restores_stage_values.sql
```

**5.4 Record pre-push report values** for comparison in Step 7:

```bash
supabase db query --linked "select * from public.report_series(
  (select id from public.workflows where name = 'Nutrition Tracker'),
  '2026-11-09', '2026-11-22', 'America/Chicago')" -o table
```

### Step 6. Push. **Needs the user's explicit go-ahead: it changes the shared dev database.**

```bash
supabase db push --linked
```

Rollback, if ever needed: a new migration that re-creates `20261115000000`'s body verbatim
(`create or replace`). No data migration is involved either way. Snapshots written in the new
format stay readable by the old reader and by `report_series`. `item_events` is append-only, so
there's nothing to undo.

### Step 7. Post-push verification on dev

1. `supabase db query --linked -f scripts/move_stage_backward_dev_check.sql` → `PASS …`.
2. `supabase db query --linked -f scripts/report_series_dev_check.sql` → `PASS … 33 bad configs
   rejected …` (the Step 2 version).
3. Re-run 5.4's query. It must be **identical** to the pre-push output. The migration changes no
   data, and `report_series` is unchanged. If some real Nutrition item moved in between,
   explain the difference before calling this done.
4. Optional (needs the user, on the phone, on a throwaway or today's item): use the chat to say
   "move it back to breakfast". Breakfast's own numbers should show, and moving forward should
   show the later meal's numbers again. Skip this if the user doesn't want to touch real data.
   Steps 7.1–7.2 already cover the behaviour.

### Step 8. Commit, then push to `main`. Each needs its own go-ahead

**Does not include `PROGRESS.md`.** Per `CLAUDE.md`, `PROGRESS.md` changes only at a milestone
the user invokes. That's the same convention the Report plan's Step 9 followed. This commit is
self-contained without it; Step 9 is the carry-forward list for that later milestone.

**Commit contents (default):**
- `supabase/migrations/20261116000000_move_stage_restores_stage_values.sql`;
- `scripts/report_series_dev_check.sql` (the Step 2 one-line change);
- `scripts/move_stage_backward_dev_check.sql`;
- `plans/move-stage-backward-snapshot/` (this plan's drafts, reviews and final plan);
- `plans/generic-report-feature/` (the Report plan's trail).

**Why both plan directories get the same treatment, and why it's still a question.** Repo
precedent is that plan directories are committed: `plans/diet-workflow/`,
`plans/github-pages-deploy/` and `plans/prod-instance-setup/` are all tracked, sometimes in the
feature's own commit, sometimes in a separate "record the plan's trail" commit. So the default for
**both** untracked plan directories is "commit". The Report feature's commit (`169c23f`) left
`plans/generic-report-feature/` out, though, and nothing records whether that was deliberate. So
ask once, covering both directories: *"I'll commit both plan directories (this one and the
Report plan's), as with earlier plans. OK, or leave either out?"* If the user wants the Report
directory committed separately (as `d4bf4f1` did for the Pages plan), make it a second commit
rather than mixing it into this one. The repo is public, so skim both directories for anything
that shouldn't be published before staging (none expected: they contain the dev project ref,
which already appears in tracked plans, and no keys).

Stage by explicit path, not `git add -A`. **Never** stage `plans/diet-workflow/test-plate.jpg`:
it's intentionally uncommitted (personal photo, public repo). Run `git status` after staging to
confirm it's still untracked.

The message should explain *why*: backward moves left a later stage's values in `item.data`,
the next forward move filed them as the earlier stage's snapshot (overwriting its real value),
and the later stage's own value was lost; now every sequenced move saves the departing stage and
restores the arriving one.

Push to `main` only with the go-ahead. It doesn't trigger `deploy-pages.yml` (no `web/**`
changes).

### Step 9. `PROGRESS.md`: carry-forward for the next user-invoked milestone (not an action of this plan)

Nothing in Steps 1–8 depends on this, and no step of this plan edits `PROGRESS.md`. When the user
next asks for a milestone, carry these into it:
- Delete the "Known limitation" section and the Outstanding bullet "Plan and fix the `move_stage`
  backward-move residual limitation".
- Add one line under the Report entry: backward moves now save and restore per-stage values
  (`20261116000000`), verified by `scripts/move_stage_backward_dev_check.sql`.
- Add `20261116000000` to the "Dev-only features not yet ported to prod" list, noting it depends on
  `20261113000000` and `20261115000000`.
- Record A.1's answer.

If the plan stops before Step 6 (A.1 declined, or a no-go at any gate), the "Known limitation"
section stays as it is.

---

## 4. Assumptions not verified

- **Management API and `set local role`/`reset role` inside `DO`.** The Report scripts did this on
  dev successfully (PROGRESS.md records their PASS), and the new script uses the same pattern. The
  fallback is the same as before: the dashboard SQL editor.
- **No backward moves between drafting and push.** Step 5.1 checks this instead of assuming it.
- **Nothing outside `move_stage`/`report_series` reads `stage_changed.data`.** Taken from the Report
  plan's 0.1 (re-grepped for `move_stage` callers here: only `WorkflowApiClient.MoveStageAsync`,
  `agent-loop` and `mcp-server`, and none of them reads the event's `data`). Not re-audited for
  every `item_events` reader.
- **Users (and the agent) want a returned-to stage to show its own values.** This is the substance
  of A.1. The plan assumes "yes" by default but doesn't proceed without the answer.

## 5. Risks and edge cases

- **Fifth redefinition of `move_stage`.** Mitigated by the literal body, the Step 5.3 diff, and
  both scripts. Script 1 re-asserts `enforce_stage_order` (check 9) and mechanic `data = null`
  (check 8).
- **`item_agg: last` semantics shift while an item is parked** (generic engine, no current
  consumer). `last` picks the highest-`seq` segment. While an item is parked back at an earlier
  stage, the earlier stage's live value (seq ∞) is "last", even though a later stage holds a
  later-in-the-day value. Before this fix the carried-over value made `last` look like the later
  stage's value, by accident.
  - No shipped config uses `item_agg: last`. Nutrition's `weight_lbs` isn't reported.
  - If a future config does (for example a weigh-in that should mean "latest stage in sequence"),
    `last` should order by stage `sequence_order` rather than `seq`. That's a `report_series`
    decision for when such a config exists. Flagged, not changed. It's documented where it'll be
    found: the new migration's header comment (Step 1), next to the change that causes it.
- **Partial checklist overlap** (generic engine, not present in any workflow). Only keys shared by
  the two stages are cleared, snapshotted or restored. That's the same rule forward moves already
  use. A key in A and C but not B still rides along A → B → C as today. Unchanged and out of scope.
- **Old-format snapshots** (written between now and the push, if any forward moves happen). They
  are read correctly. The one gap is the deleted-value case D2 fixes, and it can't arise from a
  snapshot written before restore existed.
- **Event volume.** A Nutrition move with nothing logged now writes a six-null `cleared` object
  instead of `null`. That's negligible.
- **Equal `sequence_order` lateral moves.** Not present. They'd behave as today (nothing touched).

## 6. Out of scope (deliberate)

- Everything about the Report feature's scope (the four averages, `item_requires`, derived
  calories, the page). Not reopened.
- `report_series` changes, including its now-stale header comment wording (D4) and the `last`
  ordering note (Section 5).
- Non-checklist keys (`description`, `eaten`) carrying across stages in both directions.
  Unchanged; not reported.
- Recovering per-stage values lost before `20261115000000` (items `a831e45f`, `8c4775d6`). The
  Report plan's D2 already covers this, and this fix doesn't change it. A backward move on those
  items now restores nothing for the earlier stage (honestly blank) instead of showing the later
  stage's values.
- An agent tool-description tweak (D5), and any UI backward-move control or warning.
- Porting to prod. Carried into `PROGRESS.md` at the next milestone (Step 9) as depending on the
  two earlier `move_stage` migrations.

---

## Feedback from this round

The round-1 sanity-check file (`round-1-sanity-check.md`) isn't in the plan directory. Its points
are taken from the orchestrator's summary of it.

**Plan-reviewer**

1. *Step 9's "at the milestone" conflicts with CLAUDE.md's user-invoked milestone* (serious).
   **Adopted.** Step 9 is now explicitly a carry-forward list for the next user-invoked
   milestone, the same pattern as the Report plan's Step 9. No step of this plan edits
   `PROGRESS.md`. I chose deferral over "edit it as part of this plan" because CLAUDE.md says so
   and the Report feature set the precedent.
2. *Step 8's commit includes Step 9's not-yet-existing update* (serious). **Adopted** (follows
   from 1). Step 8 now says outright that `PROGRESS.md` is not in the commit, and Step 9 says
   nothing in Steps 1–8 depends on it. No renumbering needed.
3. *A.1 has no "no" path.* **Adopted.** A.1 now has "If you decline": implement nothing, record
   it, offer (a) clear-without-restore, (c-alt) refuse, or leave as is (costs restated), then
   re-plan the chosen option as a new round. I deliberately did **not** pre-write a fallback
   migration. Each alternative changes Step 1's body and Step 3's expected values, and an
   un-reviewed second body inside this plan would be the riskier option.
4. *Section 1 item 4 summarizes only one of Step 9's edits.* **Adopted.** It now lists all three,
   and says the edits are deferred.
5. *D6 undercounts the diff relative to Step 5.3.* **Adopted.** D6 now lists the same five
   regions plus the two dropped comment tails, matching Step 5.3's expectation.
6. *The two untracked plan directories are treated asymmetrically.* **Adopted, settled the same
   way for both.** Repo precedent (three tracked plan directories) makes "commit" the default for
   both. One question to the user covers both, because the Report commit's omission may have
   been deliberate. The Report directory can go in a separate commit if wanted. Also added:
   stage by explicit path, plus a `git status` check that `test-plate.jpg` stays untracked.
   Added the commit ask to Section A's go-ahead list.

**Sanity-check**

- *Flag the `item_agg: last` + shared key consequence in a comment.* **Adopted, in a different
  place than suggested.** Putting it in `report_series` or the validator's comment would mean
  either redefining `report_series` (which D4 avoids) or editing the already-applied
  `20261115010000` file (which must not change after being pushed). It now goes in the new
  migration's header comment, next to the change that causes it, and Section 5 points there.
  It's a SQL comment outside Step 5.3's diffed range, so it doesn't affect the gates. Step 4's
  "already done while drafting" note mentions the addition.
- *Re-check vs push gap (not a transaction).* **Adopted as a sentence** in Step 5.1: the re-check
  narrows the window rather than closing it; run Step 6 promptly; Step 7.3 would surface a stray
  move; the remedy is unchanged.

**Not reworked (both reviews said they held up):** the restore-on-both-directions design (D1),
the literal migration SQL, the snapshot format (D2), Section 0's ground-truth queries, both
check scripts, Step 4–7 gates.
