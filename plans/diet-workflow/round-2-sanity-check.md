# Round 2 sanity-check — Diet workflow plan

Reviewed `plans/diet-workflow/round-2-draft.md` cold (round 1's sanity-check was not read, per
the pipeline's independence rule). Cross-checked against the live repo: `web/Pages/WorkflowDetail.razor`,
`web/Services/WorkflowApiClient.cs`, `supabase/functions/agent-loop/index.ts`,
`supabase/functions/scan-vin/index.ts`, and the relevant migrations (20261012035437,
20261012154028, 20261016130000, 20261020200000, 20261101000000, 20261108030000).

## Overall

Strong, well-grounded draft. Every empirical claim checked against actual code held up exactly —
line numbers, the "Job #" sweep (only the C# comment at line 403 remains outside the four edited
lines 56/108/118/173), the `StageSummary`/`WorkflowSummary` record shapes, `DoneNextStage`'s
`Checklist.Except(OptionalChecklist)` logic, `search_items`' stage-title/job-number matching, the
`create_item` overload history across migrations, and — most importantly — the tool-error
propagation path in `agent-loop` (confirmed: a `tool_result` with `is_error:true` always produces
a plain-text model reply landing as an `("Agent", reply, ...)` chat-log row via `Send()`; an
"Error" row only comes from `Send()`'s own catch on a non-2xx/network failure at the whole-call
level). Round 2's "correction" to round 1's framing on this point is accurate.

No must-address findings. All items below are "worth considering."

## Findings

**1. (critique, minor)** One leg of D12's reasoning for rejecting "omit `create_item` from
tools" is shakier than it needs to be. The plan says this alternative "relies on unverified API
tolerance of prior `create_item` tool_use blocks in history when the tool is absent." Checked:
Anthropic's guidance (and the `mid-conversation-tool-changes` beta) does flag that removing a
tool from the `tools` array mid-conversation is a real ambiguity area — but in this codebase,
conversations are scoped per workflow/per job, and whether a workflow has an `is_initial` stage
doesn't change turn-to-turn within one conversation. So the specific failure mode described (an
in-flight conversation suddenly missing a tool its own history references) can't actually arise
here — tools would differ *between* workflow types, not *within* one conversation's lifetime.
Doesn't change the conclusion (keeping `tools` static is still right, for the plan's other solid
reasons), but the stated justification should be tightened or dropped rather than implying a risk
that doesn't apply to this architecture.

**2. (alternative, minor)** No `deno check` on `scan-plate/index.ts` before deploy. Step 6b adds
`deno check` for `agent-loop` specifically to catch type errors pre-deploy; Steps 4/5 never run
the equivalent for `scan-plate/index.ts` (only `validate_test.ts`, which doesn't import
`index.ts` at all). Since the plan's own top-listed uncertainty is whether `--use-api` bundles the
relative `./validate.ts` import correctly, adding `deno check supabase/functions/scan-plate/index.ts`
as a cheap pre-deploy step would catch import/type problems locally before burning a deploy cycle
— complementary to, not a replacement for, the documented Docker-bundling fallback. Separately
verified via web search that `--use-api`'s stated purpose (per Supabase's own changelog) is to
support exactly this kind of multi-file/relative-import bundling, so the risk is probably somewhat
over-rated as "top uncertainty" — but a local `deno check` is still a free, strictly-additive
hedge worth adding.

**3. (critique, very minor/informational)** `stages` is passed into the new `callTool` as an
untyped `any`, not a checked type. `fetchStages` returns via `await res.json()` (implicitly
`any`), and `let stages;` with no annotation stays `any` through the file. Step 6b's signature
change types the new parameter as `{ is_initial?: boolean }[]`, but because the call-site value is
`any`, `deno check` will not actually verify that the `/rest/v1/stages` query still selects
`is_initial` — if a future edit to `fetchStages`'s `select=` list ever dropped that column, the
guard would silently always see "no is_initial" as false-negative (never fires) with no compiler
signal. Low probability, zero current impact (the query already selects `is_initial`), but worth a
one-line note or an explicit type annotation on `stages` if the implementing engineer wants the
type system to actually enforce this invariant going forward.

**4. (worth considering, already acknowledged by the plan)** `MAX_KCAL = 3000` could false-reject
some legitimately large single-plate meals (e.g. a large composite restaurant plate can realistically
run 3000–4500 kcal). Doesn't need to change — the plan already lists this exact tradeoff explicitly
in Risks with a reasoned justification ("sits above a whole large pizza") and documents the
all-or-nothing UX fallback (retake / log via chat). Flagged only because the task asked for a
specific assessment of whether the bound is too tight — conclusion: it's a defensible,
already-disclosed judgment call, not an oversight.

## Answers to the four specific verification points

- **validate.ts bounds**: Not too loose — the combined `fiber_g + sugar_g ≤ carbs_g + 1` check and
  the Atwater kcal band both have real teeth beyond the per-field caps (hand-traced the `overKcal`
  test case: a combination that passes every individual per-field cap is still correctly rejected
  by the kcal band alone). Not clearly too strict either, modulo the kcal-ceiling tradeoff noted
  above, which the plan already owns.
- **agent-loop Step 6b actually prevents raw Postgres leakage**: Confirmed true, by direct reading
  of the tool-use loop and `Send()`. Round 2's "correction" to round 1's framing (errors are
  paraphrased by the model into an Agent row, never a raw Error row, for in-loop tool failures) is
  accurate — round 1's "raw Postgres exception reaches the chat log" framing was technically
  imprecise (it reaches the model raw, then gets paraphrased), but the underlying finding (the
  model can and does quote `is_initial`/the uuid/`P0001` verbatim in that paraphrase, which is
  still bad UX) was and remains valid, which is exactly how round 2 characterizes it.
- **D12's tradeoff vs. the two rejected alternatives**: The chosen precondition-guard approach is
  the best of the three considered. The 3-arg-RPC-switch alternative is correctly rejected as pure
  churn with no behavior change. The "omit from tools" alternative is correctly rejected for its
  stronger reasons (static-prefix simplicity, deterministic model-facing message) even though one
  supporting argument (finding #1 above) is weaker than stated.
- **validate.ts deploy-time risk**: Adequately hedged (documented two-step fallback: drop
  `--use-api`, then inline). Adding a local `deno check` (finding #2) would make the hedge slightly
  cheaper to exercise, but not blocking, and inlining preemptively is not recommended — multi-file
  relative imports within one function directory are exactly what `--use-api` was built to support,
  per Supabase's own changelog, and the existing fallback plan is sufficient.

## Verdict

**No revision round needed on substance.** All findings above are minor/optional — none change a
decision, a number, or a code path the implementing engineer would need to redo. This draft is
ready to advance to architect review as-is; the two "worth considering" code-level items (`deno
check` for scan-plate, loosening the D12 justification text) can be picked up during
implementation without another sanity-check pass.
