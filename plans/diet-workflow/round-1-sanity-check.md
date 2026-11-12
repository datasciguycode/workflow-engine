# Sanity check: Diet workflow round-1 draft

Reviewed against the live code (`web/Pages/WorkflowDetail.razor`, `web/Services/WorkflowApiClient.cs`,
`supabase/functions/scan-vin/index.ts`, `supabase/functions/agent-loop/index.ts`) and the migrations
under `supabase/migrations/`, not just the draft's own description of them. Most of the draft's factual
claims about the current code check out exactly as stated (verified below); the findings here are about
the places where either a claim doesn't fully hold up, or the chosen fix/scope is the wrong call.

## Must address before implementation

### 1. scan-plate's validation is not actually "the same spirit as scan-vin's VIN regex" — it's much weaker, and the plan defers the fix instead of making it

This is the one thing the task explicitly asked to scrutinize, and it doesn't hold up. scan-vin's
`VIN_PATTERN` is a hard structural invariant: a 17-character string from a fixed alphabet is either a
plausible VIN or it provably isn't, and almost any hallucination gets caught by format alone. scan-plate's
`MAX_GRAMS = 2000` ceiling is not a comparable check — it's described as "a sanity ceiling, same spirit as
scan-vin's VIN regex," but 2000 g of protein (or fat, or sugar) from one plate is off by roughly an order
of magnitude from anything a real meal could contain. A hallucinated or badly-estimated number essentially
always lands inside `[0, 2000]`, so this check will reject almost nothing in practice. It is not "same
spirit," it's much looser.

Worse, the plan's own Risks section (§5, "Cross-field plausibility") *identifies* the real gap —
`sugar_g`/`fiber_g` greater than `carbs_g` isn't rejected — and then explicitly defers it: "Step 7 checks
it manually. If it shows up in practice, add the check to `parseEstimate`." For food-macro estimation,
which the task description correctly calls "a much fuzzier output space" than a VIN, this is backwards:
the cheap, purely-structural checks (fiber and sugar are subsets of total carbs by the prompt's own stated
convention; total calories from 4P+4C+9F falls in a plausible single-meal band) are nearly free to encode
and don't depend on noticing a bad case during one ad hoc manual test run.

**Fix**, consistent with D9's own "all-or-nothing, reject rather than write a wrong-looking complete
estimate" philosophy — add to `parseEstimate` before accepting an estimate:
- Tighten `MAX_GRAMS` to a realistic per-nutrient band (e.g. protein/carbs/fat ≤ 400 g, fiber/sugar ≤ 150 g
  for a single plate), not a single shared 2000 g ceiling.
- `fiber_g <= carbs_g` and `sugar_g <= carbs_g` (the system prompt itself already states carbs includes
  both).
- `4*protein_g + 4*carbs_g + 9*fat_g` within a plausible single-meal band (the plan's own Step 7 pass
  criterion uses 350–1300 kcal for pass/fail by hand; encode a looser version, e.g. 20–2500 kcal, as a
  reject-to-null gate in the function itself).

None of this requires model changes or new fields — it's the same shape of check D9 already describes,
just not written into the code.

### 2. Diet chat can still trigger `create_item`, which is guaranteed to fail with a raw Postgres error surfaced to the user — and this isn't acknowledged anywhere

`ChatAvailable` (plan §3, 9i) hides chat only on the *New* screen when there's no `is_initial` stage
(D7). It does **not** hide chat once a Diet entry is open (`_selectedItem is not null` is enough on its
own). But `agent-loop`'s `create_item` tool (verified in `supabase/functions/agent-loop/index.ts` lines
193-197) always calls the 2-arg `create_item(p_workflow_id, p_data)` RPC regardless of what's selected —
and that RPC (verified in `20261012154028_phase1_is_initial_and_seq.sql`) unconditionally does `raise
exception 'workflow % has no is_initial stage'` when none exists, which is exactly the Diet workflow's
shape.

So: open a Breakfast entry, type "log another snack for me" or "add a lunch entry" into chat — a perfectly
natural thing to type on a screen that also has an explicit "+ New Entry" button one tap away — and the
agent will call `create_item`, the RPC will throw, and the user sees a raw Postgres exception string in
the chat log (`Error: workflow 33333333-... % has no is_initial stage` or similar), not a helpful
redirect to the stage chooser. The plan explicitly keeps `agent-loop` untouched (D7: "`agent-loop` is not
modified") and Step 11's regression checklist never exercises this path (it only tests "bump protein to
30g," i.e. `update_data`). This is a reachable, not-even-unlikely failure mode in ordinary use that the
plan neither fixes nor lists as an accepted risk.

**Fix options, in order of preference**: (a) cheapest — add one line to §5 Risks explicitly calling this
out as an accepted gap (consistent with the plan's own "agent-loop wording is untouched per scope" risk
entry just above it), so it's a documented decision rather than a blind spot; or (b) better — since D7
already establishes a pattern of hiding UI, also suppress the chat's create-capability specifically for
all-terminal/no-initial workflows once an item is open (e.g. don't send the `create_item` tool definition
to Claude at all when the active workflow has no `is_initial` stage — a few-line change to
`agent-loop`'s tool list construction, not the "touching agent-loop's prompt wording" the plan is trying
to avoid).

## Worth considering

### 3. `AllStagesTerminal` conflates two different concerns that the plan itself warns against conflating elsewhere

D3 explicitly argues `group_items_by_date` must be its own flag, separate from lifecycle shape, because
"Coupling them would surprise the next workflow that wants one without the other." `AllStagesTerminal`
(the fix for both `VisibleItems()` and `DoneNextStage()`) does exactly the kind of coupling D3 warns
about, just in the other direction: it derives "nothing is ever hideable as closed" from "every stage is
terminal." Those happen to coincide for Diet (flat peer categories, nothing ever closes) and for the
mechanic workflow (a real pipeline with exactly one non-terminal-free... well, it has non-terminal
stages, so it's unaffected either way) — but they won't necessarily coincide for the next workflow. A
workflow with several genuine terminal *outcomes* (e.g. resolved / dismissed / duplicate on a ticket
triage flow, still with no pipeline after that) would also be "all stages terminal" by this predicate, yet
plausibly still wants "dismissed" items hidden by default — exactly the behavior `AllStagesTerminal`
removes wholesale (it also deletes the Show/Hide-closed toggle entirely in 9f).

This isn't a bug for Diet today, and the plan's own precedent (D1, rejecting an explicit flag for the
stage chooser) argues against adding a knob with no current user — so I'm not asking for a new column
here. But the plan should at least name this coupling as a known limitation in §5 (the way D3 names the
reporting-tool timezone follow-on), the same way it already flags the "Not fixed here" overview-page
navigation issue. Right now the risk section is silent on it.

### 4. Search results for Diet still regress to the exact "meaningless" title the plan just fixed elsewhere

D6 is explicit that `ItemTitle`'s id-fragment fallback ("Entry 3fa2b1c0") is meaningless for Diet, which
is why the grouped list gets its own card format (stage + time) instead. But 9g/Step 11 leaves search
results as a flat list using the *unmodified* card, which still calls `@ItemTitle(item)` — so searching
"breakfast" on the Diet workflow (a scenario the plan's own Step 11 test script calls for) will render
cards headed `#1 Entry 3fa2b1c0 →` / `Stage: Breakfast`, i.e. precisely the meaningless heading D6
motivated moving away from. The plan calls search "exempt from list-display rules" without noting that
exemption reintroduces the specific problem it just solved for the plain list. Minor — worth either a
one-line card tweak for search results too, or at least an acknowledgment in Step 11 of what the card will
actually look like.

### 5. Step 7's token hand-off assumes a human at an interactive terminal, with no stated mechanism for how the secret reaches whoever runs the `curl` commands

The plan is right that reading `access_token` out of `localStorage` via DevTools is a safe, read-only
operation, and right to specifically warn against minting a fresh token from the stored `refresh_token`
(GoTrue rotates refresh tokens on use, and reusing it outside the window can revoke that session family —
the exact side-effect-on-the-real-browser-session risk the task asked about is correctly identified and
avoided). That part of Step 7 is sound.

What's unstated is *who* executes `read -rs SB_JWT; export SB_JWT` and the subsequent `curl`. That command
needs a live interactive stdin to paste the secret into without it appearing in any transcript/history —
which works fine for a human engineer at their own terminal, but has no defined equivalent for a
non-interactive execution context (e.g., an agent running these as scripted shell calls has no live
terminal to paste into, and would have to receive the token some other way — e.g. pasted into chat, which
is exactly the kind of exposure `read -rs` was trying to avoid). Not a blocker — the obvious resolution is
"a human runs Step 7 directly" — but the plan should say that explicitly rather than leaving it implicit
in a step otherwise written as literal shell commands to execute.

### 6. Stage-chooser and date-grouping additions are proportionate, not over-engineered — no finding here, stated for completeness

Checked specifically per the task's prompt: D1 (derive the chooser from "no `is_initial` stage," reject a
new flag) and D3 (a single boolean for date grouping, reject a "view mode" enum) are both minimal and
match the single current need without adding speculative configurability. `item_label_plural` (D2) is
likewise a single nullable column with a backward-compatible fallback. These are the right size for a
one-workflow need; I don't have a cheaper alternative to propose for any of the three.

## Verified claims that hold up (no finding, included so the architect doesn't need to re-check them)

- `VisibleItems()`/`DoneNextStage()`'s current behavior, and the "at least one required field / at least
  one non-terminal stage" assumptions the plan diagnoses, match the live code exactly
  (`WorkflowDetail.razor` lines 511-514, 665-672).
- The 3-arg `create_item(uuid, uuid, jsonb)` overload's history (dropped by phase1, recreated by phase4b
  with `stage_id` logging) matches the migrations exactly, and Postgres's default implicit `EXECUTE ...
  TO PUBLIC` on function creation is a real, correct explanation for why `authenticated` already has
  execute on it without an explicit grant ever being re-issued after the drop/recreate.
- `stages_one_initial_per_workflow` is a *partial unique* index (`where is_initial`), not a NOT-NULL/CHECK
  constraint requiring at least one — so a workflow with zero `is_initial` and all `is_terminal` rows is
  schema-legal today, as the plan assumes.
- `AuthState`'s localStorage key format (`workflow-app.auth-session.<host-prefix>`) matches exactly.
- `search_items` is genuinely field-name-agnostic (matches `jsonb_each_text` values + stage title + job
  number), so it will work unmodified for Diet's checklist keys as claimed.
- `config.toml` has no `[functions.scan-vin]` or `[functions.agent-loop]` block, confirming `verify_jwt`
  defaults to true for both, matching the plan's claim for scan-plate.
- `GetStagesAsync`/`StageSummary` already select and carry `optional_checklist` — the plan correctly
  doesn't need to touch that path, only `WorkflowSummary`/`GetWorkflowAsync`/`GetWorkflowsAsync`.
- `ItemLabelPlural`'s current `+ "s"` fallback, and `Home.razor` never constructing a `WorkflowSummary`
  itself, both check out — the record's added fields are additive with no other call site to update.

## Summary

- 2 must-address findings (both critique/correctness): scan-plate's validation is materially weaker than
  the VIN check it's compared to and the plan defers rather than fixes a gap it already identified; the
  Diet-chat `create_item` path is a reachable, user-facing failure mode that's neither fixed nor
  documented as an accepted risk.
- 1 worth-considering critique (the `AllStagesTerminal` predicate conflates lifecycle and display
  semantics in a way the plan's own D3 reasoning argues against, though it's correct for today's two
  workflow shapes).
- 1 minor worth-considering critique (search cards regress to the meaningless title fallback D6 just
  fixed for the plain list).
- 1 worth-considering feasibility/clarity note (Step 7's token hand-off has no stated actor).
- 1 non-finding, stated for completeness (stage-chooser/date-grouping sizing is appropriate, not
  over-engineered).

**Verdict: another revision round is needed before architect review**, but a small one — scoped to
tightening `parseEstimate`'s validation (finding 1) and resolving/documenting the chat `create_item` gap
(finding 2). Nothing else here blocks advancing; the rest is worth folding in opportunistically but
wouldn't by itself justify another round.
