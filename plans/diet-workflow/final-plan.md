# Diet workflow: final implementation plan

**Verdict: `approved-with-changes`.** The round-2 design stands as written. This final pass
changes a few things, listed in the "Architect adjudication" section at the end:
- One deferred decision is now settled. Diet entries open straight into their own stage view, and
  the generic stage overview page is skipped (D13, Step 9a/9l).
- One small correctness fix in the scan handler: it no longer yanks the user back to an entry they
  navigated away from mid-scan.
- Several executability fixes:
  - a durable test-photo path with a fallback;
  - `deno check` on scan-plate;
  - an exact before/after for the Show-closed wrap;
  - an honest D12 justification;
  - corrected migration comments;
  - an explicit push-before-phone-test ordering.

Dev only: repo `/home/mmcbride/micah/claude/workflow-app`, Supabase project `workflow-engine-test`
(ref `utwyvtbzesswpoihmlic`, already the linked project per `supabase/.temp/project-ref`). Nothing
here touches `/home/mmcbride/micah/claude/workflow-app-prod` or its project.

## 0. Ground truth (checked read-only, 2026-11-11)

- **Live dev workflows.** There are four:
  - "Acct 1 workflow" and "Acct 2 workflow" (isolation fixtures).
  - "Feature Pipeline" (`ticket`).
  - "Joe's Auto Repair": id `33333333-3333-3333-3333-333333333330`, account
    `11111111-1111-1111-1111-111111111111`, `item_label = 'job'`.

  There is no "Diet" yet. Mechanic stages: intake (is_initial) → scheduling → diagnosis → estimated →
  approval → in_progress → invoicing → payment_receipt_submitted (seq 8, is_terminal) → closed (seq
  null, is_terminal, no checklist). Every mechanic stage with a checklist has at least one required
  field.
- **`create_item` has two overloads on dev**, and `authenticated` can EXECUTE both.
  - `create_item(uuid,jsonb)` (phase1, fixed by `20261020200000`) is the canonical one. It looks up
    the is_initial stage and raises `workflow % has no is_initial stage` when there is none.
  - `create_item(uuid,uuid,jsonb)` was dropped in phase1, then re-created by phase4b's
    `create or replace`. It inserts into `p_stage_id` and logs `item.created` with that `stage_id`.
    It does **not** copy `p_data` into the event, which is harmless because we pass `{}`.
  - The composite FK `items(stage_id, workflow_id) → stages(id, workflow_id)` stops a stage from
    another workflow being used.
- **`is_terminal` is a UI/reporting hint, not a write block** (phase1b's own comment). `move_stage`
  never checks it.
- **agent-loop tool errors** (`supabase/functions/agent-loop/index.ts`, lines 409–437).
  - When `callTool` throws, the error is logged to `agent_events` and fed back to the model as an
    `is_error: true` tool_result with content `error: <e>`. The system prompt tells the model to
    explain failures in plain text.
  - So a tool failure reaches the user as the model's paraphrase in an **Agent** chat row. **Error**
    rows are only for HTTP-level failures of the whole agent-loop call.
  - The existing convention for tool preconditions is a plain `throw new Error("...")` inside
    `callTool`.
  - `TOOLS` is one static module-level array. The system prompt is rebuilt per request and already
    embeds the workflow's stages JSON.
- **`workflows` has only `item_label`.** `ItemLabelPlural` is `ItemLabelSingular + "s"`, so "entry"
  would render as "Entrys".
- **Auth.** `AuthState` keeps the session in localStorage under
  `workflow-app.auth-session.utwyvtbzesswpoihmlic` as JSON
  `{access_token, refresh_token, expires_at, email}`.
- **Tooling.**
  - Supabase CLI v2.120.0. Don't upgrade it.
  - Docker is installed, but the convention is `functions deploy --use-api`.
  - Deno 2.9.7, `python3`, `curl` and `base64` are present. `jq` and ImageMagick are not.
- **Test photo.** A 2016x1512 JPEG of 1.29 MB, about 1.7 MB as base64. That's under the Anthropic
  per-image limit. See Step 7 for where it lives.

## 1. What the Diet shape breaks in existing generic code (must fix)

Diet's shape is "5 peer stages, all terminal, none initial, nothing required". In that shape:

1. **The list would be empty by default.** `VisibleItems()` hides items in terminal stages unless
   "Show closed" is on.
2. **"Complete Stage" would appear and move breakfast → lunch.**
   - `DoneNextStage()`'s required set is empty, so its `.All(...)` check is vacuously true.
   - Gating on `stage.IsTerminal` instead is wrong. The mechanic's terminal
     `payment_receipt_submitted` correctly offers Complete Stage → `closed` today.
3. **The New-item screen and chat assume an initial stage.**
   - Other Appointments renders on it unconditionally.
   - Chat there can only call `create_item`, whose 2-arg RPC raises.
   - Chat on an open entry can also hit `create_item` ("add a lunch entry").
4. **The generic stage overview page is wrong for Diet.**
   - Tapping an entry opens 5 stage cards, and the 4 meal cards show identical "done" ticks because
     they share keys.
   - Drilling into a *non-current* meal card shows Scan Plate and chat, which would write onto the
     entry that is open. That's a real data-confusion path, not just a cosmetic one.
5. **Hardcoded "Job" text.**
   - `Job #N` headings (lines 56, 118).
   - The `Search jobs...` placeholder (line 193).
   - The `ItemTitle` fallback `ItemLabelPlural.TrimEnd('s')`, which turns "Entries" into "Entrie".
   - The two Other Appointments `Job #` lines (108, 173), which Diet never sees but which are swept
     for completeness.

   Every swap to `ItemLabelSingular`/`ItemLabelPlural` is a no-op for the mechanic (`job` → "Job").

Items 1, 2 and 4 all follow from one derived predicate, **`AllStagesTerminal`**: every stage is an
end state, so items never move. In such a workflow:
- nothing is "open", so nothing is hidden as closed;
- nothing can be "completed" into a next stage;
- a pipeline-progress overview has nothing to show.

The mechanic and Feature Pipeline both have non-terminal stages, so they're untouched.

## 2. Decisions

- **D1. The stage chooser triggers only when there is no `is_initial` stage.** That's exactly the
  condition under which the existing path can't work.
  - Rejected: a `choose_stage_on_create` flag. It would be a knob with no current user.
- **D2. Nullable `workflows.item_label_plural`.** When it's null, the UI falls back to `+ "s"`.
  - Rejected: a label that pluralizes with "s". It dodges the "entry/entries" requirement.
  - Rejected: a C# pluralizer.
- **D3. An explicit `workflows.group_items_by_date boolean not null default false`.** It is not
  derived from stage shape. Grouping is a display preference, not lifecycle semantics.
- **D4. Grouping uses the browser's local date** (`CreatedAt.ToLocalTime().Date`), not the UTC
  `created_at::date`. Note timestamps already use `ToLocalTime()`.
- **D5. Day order:** days newest-first, entries within a day oldest-first.
- **D6. When `group_items_by_date` is on, cards read `#N {Stage} →` plus a time line**, in both the
  grouped list and search results. Search stays flat, so its line also carries the date. Mechanic
  cards are untouched.
- **D7. Chat is hidden on the chooser screen**, via a single `ChatAvailable` property that replaces
  the two duplicated `_newJobMode || _selectedItem is not null` conditions.
- **D8. The new client wrapper `CreateItemInStageAsync` calls the existing 3-arg `create_item` RPC
  directly.** This is the same direct-RPC-wrapper pattern as `MoveStageAsync`/`UpdateDataAsync` for a
  deterministic UI action.
  - It returns the new id, and the UI drills into exactly that item.
  - This makes the 3-arg overload a deliberately supported, client-called API. It was previously
    called the "old" overload, alive only by accident. Migration A's comment and grant say so
    explicitly.
- **D9. scan-plate is all-or-nothing, with concrete validation** in a unit-tested `validate.ts`:
  - per-nutrient caps;
  - `fiber + sugar ≤ carbs + 1 g`;
  - a 10–3000 kcal Atwater band.

  Any failure returns five nulls plus the model's note. That mirrors scan-vin's `{vin: null}` with a
  200. The rejection reason is logged server-side only.
- **D10. The uncertainty note is shown transiently, scoped to the item it was produced for.** It is
  not persisted.
- **D11. The scan prompt asks the note to name what was identified first**, so the user can catch a
  misidentification.
- **D12. agent-loop's `create_item` tool gets a precondition guard plus one description sentence.**
  - In `callTool`, if no fetched stage is `is_initial`, it throws a plain `Error` telling the model
    to send the user to "+ New".
  - The error flows through the existing catch → `agent_events` → `is_error` tool_result → plain-text
    explanation. The mechanic's 2-arg call is byte-for-byte unchanged.
  - Rejected: switching to the 3-arg RPC. It would behave identically when an initial stage exists,
    still need the "none" branch, and only add a diff in the mechanic's working path.
  - Rejected: omitting `create_item` from `tools` for such workflows. The real reasons:
    - `TOOLS` is a single static constant today. Making it per-workflow is a new pattern for one
      edge case.
    - The description-plus-guard pair gives a deterministic, testable message instead of the model
      improvising one.
    - The guard holds even if the model ignores the description.

    (The round-2 draft also argued that a per-workflow `tools` breaks a stable prompt prefix. That
    argument is weak: the system prompt already varies per workflow. It's not relied on here.)
  - Rejected: an optional `stage_id` input so chat can create entries. That's a real feature, and a
    follow-up.
- **D13 (new, architect decision). In an `AllStagesTerminal` workflow, opening an item goes straight
  to its own stage view.**
  - The header back link there returns to the list, not to "Stages". The overview page is never
    shown.
  - This removes Section 1 item 4: no identical tick cards, and no Scan Plate or chat on a
    non-current meal stage.
  - Cost: Diet entries have no job-level notes page. Agent and checkbox notes on the stage view are
    stage-tagged and show there, which is all Diet needs.
  - It derives from the same lifecycle fact as the other two `AllStagesTerminal` behaviors: the
    overview exists to show pipeline progress, and items here never progress.

## 3. Steps

### Step 1. Migration A: generic workflow display columns + explicit 3-arg grant

File: `supabase/migrations/20261111030000_add_workflow_label_plural_and_date_grouping.sql`

```sql
-- Two per-workflow display settings needed by the Diet workflow (2026-11-11), added generically
-- on workflows rather than hardcoded to Diet in the UI:
--   item_label_plural -- item_label + "s" is wrong for anything irregular ("entry" -> "entrys");
--     nullable, and the UI keeps the old + "s" fallback when it's null, so every existing
--     workflow (job/jobs, ticket/tickets) renders exactly as before.
--   group_items_by_date -- a log-style workflow (a food diary) reads naturally grouped under
--     a date heading per day; a pipeline (the mechanic workflow) doesn't. Pure display -- each
--     item's own created_at decides its group, nothing new is stored or linked.
-- Both covered by the existing table-level grants on workflows (20261101000000), no new grant.

alter table public.workflows
  add column item_label_plural text,
  add column group_items_by_date boolean not null default false;

-- create_item(workflow_id, stage_id, data) -- the explicit-stage overload -- is from 2026-11-11 a
-- deliberately supported, client-called API: the UI's "+ New <item>" stage-chooser calls it
-- directly for workflows with no is_initial stage. (20261020200000 described it as the "old"
-- overload; it only survived because phase4b's `create or replace` re-created it after phase1
-- dropped it.) It is already executable by authenticated on dev via default privileges, but
-- nothing in this repo said so -- re-stated here so the dependency is explicit. Idempotent.
-- Note: unlike the 2-arg overload, it does not copy p_data into the item.created event; callers
-- that pass non-empty data lose stage tagging for those keys (the chooser passes {}).
grant execute on function public.create_item(uuid, uuid, jsonb) to authenticated;
```

### Step 2. Migration B: the Diet workflow content

File: `supabase/migrations/20261111040000_add_diet_workflow.sql`

```sql
-- Diet / nutrition-tracking workflow (2026-11-11), on the same generic engine, under the same
-- account as the dev mechanic workflow ("Joe's Auto Repair") -- workflow_id scoping already
-- isolates its items, so no new account. Looked up by name, not id, since this workflow's rows
-- were never fixed-id seed data; if that workflow doesn't exist (e.g. this file is ever copied
-- into the prod repo, which has no "Joe's Auto Repair") the whole block is a deliberate no-op.
--
-- Shape is deliberately unlike every workflow before it:
--   - NO is_initial stage -- there's no single natural starting point; the UI's stage-chooser
--     creates each entry directly into the stage the user picks (create_item's explicit
--     p_stage_id overload).
--   - EVERY stage is_terminal -- entries aren't meant to move. With all stages terminal the UI
--     treats nothing as "closed"/hideable, offers no Complete Stage button, and opens an entry
--     straight into its own stage view (no pipeline overview), and agent-loop's prompt already
--     skips its "move to the next stage?" nudge at a terminal stage. is_terminal is a hint, not a
--     write block, so chat can still move_stage an entry on an explicit request ("that was
--     actually lunch") -- a legitimate meal-type correction, not something the UI ever offers.
--   - checklist == optional_checklist on every stage -- nothing is ever required, so no
--     required-field "*" shows anywhere.
--   - sequence_order is display order only (stages are peers, not a pipeline);
--     enforce_stage_order stays false.
-- No day-level parent item: each meal/snack/goal change is its own item, related only by its own
-- created_at. A nutrition_goal entry is made only when targets change, not daily.
-- From here on, any content migration matching stages by title (e.g. 'breakfast') must also
-- scope by workflow_id -- earlier ones matched titles globally, which was only safe while no two
-- workflows shared a title.

do $$
declare
  v_account uuid;
  v_workflow uuid;
begin
  select account_id into v_account
  from public.workflows
  where name = 'Joe''s Auto Repair';

  if v_account is null then
    return;
  end if;

  select id into v_workflow
  from public.workflows
  where account_id = v_account and name = 'Diet';

  if v_workflow is null then
    insert into public.workflows (account_id, name, item_label, item_label_plural, group_items_by_date)
    values (v_account, 'Diet', 'entry', 'entries', true)
    returning id into v_workflow;
  end if;

  insert into public.stages
    (workflow_id, title, sequence_order, is_initial, is_terminal, checklist, optional_checklist)
  select v_workflow, s.title, s.seq, false, true, s.fields, s.fields
  from (values
    ('nutrition_goal', 1, '["protein_goal_g","carbs_goal_g","fat_goal_g","fiber_goal_g","sugar_goal_g"]'::jsonb),
    ('breakfast',      2, '["protein_g","carbs_g","fat_g","fiber_g","sugar_g","weight_lbs"]'::jsonb),
    ('lunch',          3, '["protein_g","carbs_g","fat_g","fiber_g","sugar_g","weight_lbs"]'::jsonb),
    ('dinner',         4, '["protein_g","carbs_g","fat_g","fiber_g","sugar_g","weight_lbs"]'::jsonb),
    ('snack',          5, '["protein_g","carbs_g","fat_g","fiber_g","sugar_g","weight_lbs"]'::jsonb)
  ) as s(title, seq, fields)
  on conflict (workflow_id, title) do nothing;
end
$$;
```

Notes:
- `unique (workflow_id, title)` exists (phase0), so `on conflict` is valid and the file is
  re-runnable.
- `StageTitle()` renders `nutrition_goal` as "Nutrition goal".

### Step 3. Push migrations to dev

```bash
cd /home/mmcbride/micah/claude/workflow-app
supabase db push --linked --dry-run      # expect exactly the two new files
supabase db push --linked
supabase db query --linked "select w.name, w.item_label, w.item_label_plural, w.group_items_by_date,
  s.title, s.sequence_order, s.is_initial, s.is_terminal, s.checklist = s.optional_checklist as all_optional
  from workflows w join stages s on s.workflow_id = w.id where w.name = 'Diet' order by s.sequence_order;"
```

- Expect 5 rows, all with `is_initial = false`, `is_terminal = true` and `all_optional = true`.
- Also run `select name, item_label_plural, group_items_by_date from workflows`. The other four
  workflows should show `null` / `false`.
- If the dry-run lists more than the two new files, stop and find out why before pushing.

**Accepted window.** From here until the web deploy in Step 12, the live dev site shows "Diet" with
the *old* client. That means "Entrys", an empty list, and a chat box on "+ New Entry" that would
error. Dev has no other users since the tester moved to prod, so this is acceptable. Don't create
Diet entries through the old UI.

### Step 4. New edge function `supabase/functions/scan-plate/`

#### 4a. `supabase/functions/scan-plate/validate.ts`

```ts
// Reply parsing + plausibility gate for scan-plate (2026-11-11). Kept separate from index.ts only
// so it can be unit-tested (validate_test.ts) without starting Deno.serve. Same job as scan-vin's
// VIN_PATTERN -- check the model's answer, never trust it blindly -- for a fuzzier output space:
// these checks can't prove an estimate right, but they reject anything structurally impossible or
// implausible for one plate, and the whole estimate goes (all-or-nothing), never a partial write.

// Must match the meal stages' checklist keys exactly (see 20261111040000_add_diet_workflow.sql) --
// the client writes these keys straight into item data, and the checklist's done/not-done check
// looks for these exact keys.
export const FIELDS = ["protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g"] as const;
export type Field = typeof FIELDS[number];

// Per-nutrient ceiling for ONE photographed plate/meal. Each is roughly 2-3x the largest single
// plate the field could plausibly hold (250 g protein ~ 800 g cooked chicken breast; 400 g carbs
// ~ 1.4 kg cooked pasta; 250 g fat ~ 2250 kcal of fat alone; 80 g fiber ~ 3 days' recommended
// intake), so a real meal never trips them -- anything above is a parse/unit/hallucination failure.
export const MAX_G: Record<Field, number> = {
  protein_g: 250,
  carbs_g: 400,
  fat_g: 250,
  fiber_g: 80,
  sugar_g: 250,
};

// Atwater energy (4P + 4C + 9F) for one plate. The floor rejects an "estimate" of all-zeros /
// near-zeros, which is the model failing to say not_food rather than a real meal (a plain black
// coffee also lands here -- not worth a scan; log it via chat). The ceiling sits above a whole
// large pizza (~2200-2500 kcal).
export const MIN_KCAL = 10;
export const MAX_KCAL = 3000;

// Sugars and fiber are disjoint parts of total carbohydrate (the prompt defines carbs_g as total,
// including both), so fiber + sugar can't exceed carbs. 1 g of slack absorbs the model's own
// rounding on a low-starch plate where the three are nearly equal.
export const CARB_SUBSET_SLACK_G = 1;

export type ParseResult = {
  estimate: Record<Field, number> | null;
  note: string | null;
  // Why the estimate was rejected (null on success) -- for the function log only, not returned
  // to the client, which just shows "couldn't estimate" plus the model's own note.
  reason: string | null;
};

function round1(n: number) {
  return Math.round(n * 10) / 10;
}

export function parseEstimate(text: string): ParseResult {
  // Tolerate stray prose/fences around the object: take the outermost {...}.
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  let obj: Record<string, unknown> | null = null;
  if (start >= 0 && end > start) {
    try {
      const parsed = JSON.parse(text.slice(start, end + 1));
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) obj = parsed;
    } catch {
      obj = null;
    }
  }
  const note = typeof obj?.uncertainty_note === "string" && obj.uncertainty_note.trim()
    ? obj.uncertainty_note.trim().slice(0, 600)
    : null;
  const fail = (reason: string): ParseResult => ({ estimate: null, note, reason });

  if (obj === null) return fail("no JSON object in reply");
  if (obj.not_food === true) return fail("model reported no food visible");

  // Every field must be a real finite JSON number in [0, MAX_G[f]] -- a numeric string ("18"),
  // a range ("15-20"), null, or a missing key fails the whole estimate.
  const raw = {} as Record<Field, number>;
  for (const f of FIELDS) {
    const v = obj[f];
    if (typeof v !== "number" || !Number.isFinite(v)) return fail(`${f} not a number: ${JSON.stringify(v)}`);
    if (v < 0 || v > MAX_G[f]) return fail(`${f} out of range [0, ${MAX_G[f]}]: ${v}`);
    raw[f] = v;
  }

  // Cross-field checks on the unrounded values.
  if (raw.fiber_g + raw.sugar_g > raw.carbs_g + CARB_SUBSET_SLACK_G) {
    return fail(`fiber_g + sugar_g (${raw.fiber_g} + ${raw.sugar_g}) exceeds carbs_g (${raw.carbs_g})`);
  }
  const kcal = 4 * raw.protein_g + 4 * raw.carbs_g + 9 * raw.fat_g;
  if (kcal < MIN_KCAL || kcal > MAX_KCAL) {
    return fail(`implied energy ${Math.round(kcal)} kcal outside [${MIN_KCAL}, ${MAX_KCAL}]`);
  }

  const estimate = {} as Record<Field, number>;
  for (const f of FIELDS) estimate[f] = round1(raw[f]);
  return { estimate, note, reason: null };
}
```

Why these checks and no others:
- **`fiber + sugar ≤ carbs`** is the nutritionally exact statement under the prompt's own "total
  carbohydrate" definition. It subsumes separate `fiber ≤ carbs` and `sugar ≤ carbs` checks.
- **No per-macro share or ratio checks.** Plain chicken breast, egg whites and nuts violate them.
- **No per-field minimum.** Zero fiber or zero sugar is normal.

#### 4b. `supabase/functions/scan-plate/validate_test.ts`

```ts
import { parseEstimate } from "./validate.ts";

const ok = (o: unknown) => JSON.stringify({ ...(o as object), uncertainty_note: "kale, carrots, nuts; no scale" });
const plate = { protein_g: 18, carbs_g: 33, fat_g: 52, fiber_g: 15, sugar_g: 10 };
function assert(c: boolean, msg: string) { if (!c) throw new Error(msg); }

Deno.test("test-plate numbers pass and round to 0.1", () => {
  const r = parseEstimate(ok({ ...plate, protein_g: 18.04 }));
  assert(r.estimate?.protein_g === 18 && r.reason === null && r.note !== null, JSON.stringify(r));
});
Deno.test("fenced/prose-wrapped JSON passes", () => {
  assert(parseEstimate("Here you go:\n```json\n" + ok(plate) + "\n```").estimate !== null, "fenced");
});
Deno.test("rejections", () => {
  const bad: Record<string, string> = {
    numericString: ok({ ...plate, protein_g: "18" }),
    missingKey: ok({ ...plate, sugar_g: undefined }),
    negative: ok({ ...plate, fat_g: -1 }),
    overFieldCap: ok({ ...plate, protein_g: 300 }),
    fiberPlusSugarOverCarbs: ok({ ...plate, carbs_g: 20, fiber_g: 15, sugar_g: 10 }),
    allZero: ok({ protein_g: 0, carbs_g: 0, fat_g: 0, fiber_g: 0, sugar_g: 0 }),
    overKcal: ok({ protein_g: 200, carbs_g: 400, fat_g: 150, fiber_g: 20, sugar_g: 50 }), // 3750 kcal, each under its cap
    notFood: JSON.stringify({ not_food: true, uncertainty_note: "a car" }),
    garbage: "I can't tell what this is.",
  };
  for (const [name, text] of Object.entries(bad)) {
    const r = parseEstimate(text);
    assert(r.estimate === null && r.reason !== null, `${name} should be rejected: ${JSON.stringify(r)}`);
  }
  assert(parseEstimate(bad.notFood).note === "a car", "not_food keeps its note");
});
Deno.test("carb-subset slack: fiber+sugar = carbs + 0.5 passes", () => {
  assert(parseEstimate(ok({ ...plate, carbs_g: 24.5 })).estimate !== null, "slack");
});
```

#### 4c. `supabase/functions/scan-plate/index.ts`

The header comment, imports, `MODEL`, CORS block, auth/body checks and error shape are copied from
scan-vin. The only changes are the prompt, `max_tokens`, the `parseEstimate` import and the response
block.

```ts
// Single-purpose nutrition estimate from a photo of a meal (2026-11-11). Same shape as scan-vin
// and for the same reasons deliberately NOT folded into agent-loop's tool-use chat loop: the
// photo never needs to enter conversation history (read once, discarded, never stored), no
// tool-calling is needed for a one-shot read, and a bad photo never costs a slot in the bounded
// chat turn loop or pollutes the stage's chat log. The client writes the five numbers itself via
// a direct update_data RPC call; corrections afterward ("bump protein to 30g") go through the
// normal chat/update_data path, not anything here.

import Anthropic from "npm:@anthropic-ai/sdk@0.32.1";
import { parseEstimate } from "./validate.ts";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-5-5";

type RequestBody = {
  image_base64: string;
  media_type: string;
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SYSTEM_PROMPT =
  "You are given a photo of a single meal or snack. Identify the foods visible and estimate the " +
  "TOTAL of each nutrient across everything visible on the plate, in grams: protein_g, carbs_g " +
  "(total carbohydrate, including fiber and sugar), fat_g, fiber_g, sugar_g (total sugars). " +
  "Since fiber and sugars are both parts of total carbohydrate, fiber_g + sugar_g must not exceed " +
  "carbs_g. " +
  "Respond with ONLY one JSON object -- no markdown, no code fences, no other text -- with exactly " +
  'these keys: {"protein_g": number, "carbs_g": number, "fat_g": number, "fiber_g": number, ' +
  '"sugar_g": number, "uncertainty_note": string}. Each number must be a single plain JSON number ' +
  "(your best point estimate; no units, no ranges, no strings). uncertainty_note: one to three " +
  "short sentences -- first briefly name what you identified, then flag what makes this estimate " +
  "least reliable, e.g. no size/scale reference visible for judging portions, hidden ingredients " +
  "like cooking oil, butter, dressing or sauce that could add unlisted fat or sugar, or a mixed/" +
  "composite dish that is harder to break down than separate whole foods. If no food is clearly " +
  'visible, respond with exactly: {"not_food": true, "uncertainty_note": "<one sentence why>"}';

Deno.serve(async (req) => {
  // ...OPTIONS / 405 / missing-bearer-401 / invalid-JSON-400 / required-fields-400 blocks
  // copied verbatim from scan-vin (only the error strings mention scan-plate)...

  try {
    const anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY });
    const response = await anthropic.messages.create({
      model: MODEL,
      max_tokens: 512,
      system: SYSTEM_PROMPT,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              // deno-lint-ignore no-explicit-any
              source: { type: "base64", media_type: body.media_type as any, data: body.image_base64 },
            },
            { type: "text", text: "Estimate the nutrition for the food in this photo." },
          ],
        },
      ],
    });

    const text = response.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("")
      .trim();

    // A truncated reply can still contain a parseable-looking prefix; never trust one.
    const { estimate, note, reason } = response.stop_reason === "max_tokens"
      ? { estimate: null, note: null, reason: "reply truncated (max_tokens)" }
      : parseEstimate(text);
    // Rejection reasons go to the function log (numbers only, never the image) so a rising
    // reject rate is diagnosable from the dashboard's function logs; the client contract stays
    // {five numbers | five nulls, uncertainty_note}.
    if (reason) console.warn(`scan-plate: estimate rejected: ${reason}`);

    return new Response(
      JSON.stringify({
        protein_g: estimate?.protein_g ?? null,
        carbs_g: estimate?.carbs_g ?? null,
        fat_g: estimate?.fat_g ?? null,
        fiber_g: estimate?.fiber_g ?? null,
        sugar_g: estimate?.sugar_g ?? null,
        uncertainty_note: note,
      }),
      { headers: { "Content-Type": "application/json", ...corsHeaders } },
    );
  } catch (e) {
    return new Response(JSON.stringify({ error: `scan-plate failed: ${e}` }), {
      status: 502,
      headers: corsHeaders,
    });
  }
});
```

- In the real file, write the elided request-validation blocks out in full. They are
  `scan-vin/index.ts` lines 30–59: the body of `Deno.serve` from the `OPTIONS` check through the
  required-fields 400.
- Don't extract them into a shared module. scan-vin has none, and adding one would touch scan-vin.

Deliberately not done:
- No `thinking`, same as scan-vin.
- No assistant prefill. The brace extraction already covers fences and prose.
- No retry on a rejection. The user retakes the photo instead.

#### 4d. Test and type-check (both must pass before Step 5)

```bash
cd /home/mmcbride/micah/claude/workflow-app
deno test supabase/functions/scan-plate/validate_test.ts
deno check supabase/functions/scan-plate/index.ts
```

- `deno check` may download the npm SDK on its first run. That's fine.
- If `deno check` fails only on dependency resolution (not on a type error in our code), rely on the
  deploy's bundling as the check.

### Step 5. Deploy scan-plate

```bash
cd /home/mmcbride/micah/claude/workflow-app
supabase functions deploy scan-plate --project-ref utwyvtbzesswpoihmlic --use-api
supabase functions list --project-ref utwyvtbzesswpoihmlic   # scan-plate ACTIVE, verify_jwt true
```

- **Always name the function.** A bare deploy would also push `mcp-server`.
- **No `[functions.scan-plate]` block in config.toml.** Its absence leaves `verify_jwt` on, the same
  as scan-vin.
- **No new secret.** `ANTHROPIC_API_KEY` is project-wide.
- **`./validate.ts` is in the entrypoint's import graph, so it gets bundled.**
  - If the deploy or Step 7 fails with module-not-found, retry without `--use-api` (Docker
    bundling).
  - If that also fails, inline `validate.ts` into `index.ts` and keep the test pointed at a copy.

### Step 6. Preflight check

```bash
curl -i -X OPTIONS https://utwyvtbzesswpoihmlic.supabase.co/functions/v1/scan-plate
```

Expect 200 with `Access-Control-Allow-Origin: *`. A 401 from the gateway is acceptable if scan-vin
behaves the same way.

### Step 6b. agent-loop: guard `create_item` for workflows with no initial stage (D12)

File: `supabase/functions/agent-loop/index.ts`. There are three edits.

1. **Tool description (line 115).** Append this right after
   `"It lands automatically in the workflow's is_initial stage. "`:
   ```ts
   "If no stage in the active workflow has is_initial true, this tool can't be used -- don't call it; tell the user to tap \"+ New\" above the list and pick which kind of item it is. " +
   ```
2. **`callTool` signature (lines 175–182).** Add a trailing parameter after `selectedStageId`:
   ```ts
     selectedStageId: string | undefined,
     stages: { is_initial?: boolean }[],
   ) {
   ```
   Then replace the `case "create_item":` body (lines 193–197) with:
   ```ts
       case "create_item":
         // A workflow with no is_initial stage (e.g. Diet, 2026-11-11 -- items are created into a
         // user-picked stage by the UI's "+ New" stage-chooser instead) would otherwise hit the
         // RPC's raw `workflow <uuid> has no is_initial stage` Postgres exception, which the model
         // then relays more or less verbatim. Checked here first, same precondition-throw pattern
         // as the no-open-job checks below, so the model gets a plain reason it can pass on.
         if (!stages.some((s) => s.is_initial)) {
           throw new Error(
             'this workflow has no starting stage, so new items can\'t be created from chat -- tell the user to tap "+ New" above the list and pick which kind of item it is',
           );
         }
         return await restFetch("/rpc/create_item", jwt, {
           p_workflow_id: workflowId,
           p_data: input.data ?? {},
         });
   ```
3. **Call site (lines 412–419).** Add `stages,` as the last argument after
   `body.selected_stage_id,`. `stages` is already in scope from `fetchStages` (line 338).

Nothing else in agent-loop changes.

```bash
cd /home/mmcbride/micah/claude/workflow-app
deno check supabase/functions/agent-loop/index.ts
supabase functions deploy agent-loop --project-ref utwyvtbzesswpoihmlic --use-api
supabase functions list --project-ref utwyvtbzesswpoihmlic   # agent-loop ACTIVE, version bumped
```

- **Assumption:** the deployed agent-loop equals repo HEAD. Redeploying HEAD plus the guard is the
  intended state either way.
- **Rollback:** `git checkout <pre-change commit> -- supabase/functions/agent-loop/index.ts`, then
  redeploy.
- The guard is inert for workflows that have an initial stage.

The functional test is Step 11 item 7.

### Step 7. Real end-to-end test of the deployed scan-plate (required, human-run)

**Who runs this.** The implementing engineer, at their own terminal, with a desktop browser that's
signed in to the app and has DevTools.
- The token is pasted via `read -rs`, so it never lands in shell history or any transcript.
- An executing agent hands this step to the human and must **not** ask for the token in chat.

**The reference photo.** The plate photo captured during planning is at a session-scoped path:
`/home/mmcbride/.claude/uploads/750872d2-abc1-4109-ae9e-41bd21b23f2f/50cc0461-image.jpg`.
- **Before implementation starts**, copy it somewhere durable:
  `cp <that path> /home/mmcbride/micah/claude/workflow-app/plans/diet-workflow/test-plate.jpg`
  - Don't commit it by default. The dev repo is public (Pages), and it's a 1.3 MB personal photo.
    Commit it only if the user says so.
- Set `PLATE=/home/mmcbride/micah/claude/workflow-app/plans/diet-workflow/test-plate.jpg`.
- **If neither copy exists**, photograph any plate whose contents you can list. Write your own rough
  hand estimate and replace the band table and dominant-macro check below with ones derived from it.
  The code-level gates don't change. Only the plate-specific accuracy checks are photo-dependent.

**Token.**
1. Open `https://datasciguycode.github.io/workflow-engine/` and sign in. If you're already signed in,
   reload and open any workflow so a near-expiry token refreshes.
2. In the DevTools console, run:
   `JSON.parse(localStorage.getItem("workflow-app.auth-session.utwyvtbzesswpoihmlic")).access_token`.
   Check `.expires_at` against `Date.now()/1000`. Tokens last about 1 h.
3. In the shell, run `read -rs SB_JWT; export SB_JWT`.

Don't use the stored `refresh_token` with curl. GoTrue rotates refresh tokens, and replaying the
browser's one can revoke that session family.

**The call.**
```bash
D=$(mktemp -d)
python3 -I -c 'import base64,json,sys; print(json.dumps({"image_base64": base64.b64encode(open(sys.argv[1],"rb").read()).decode(), "media_type": "image/jpeg"}))' \
  "$PLATE" > "$D/plate-body.json"
curl -sS -w '\nHTTP %{http_code}\n' -X POST https://utwyvtbzesswpoihmlic.supabase.co/functions/v1/scan-plate \
  -H "Authorization: Bearer $SB_JWT" \
  -H "apikey: sb_publishable_Ec1_eTAJtWMb2AaC1ULE7w_8f0BvYsk" \
  -H "Content-Type: application/json" \
  --data-binary @"$D/plate-body.json"
```
If this errors on size, test via the UI path instead, which resizes to 1600 px.

**Pass criteria for the reference photo.** The plate holds 2 lacinato kale leaves, 2 carrots, ½
avocado, about 14 almonds, about 25 g walnuts and about 2 tbsp peanut butter. The hand estimate is
P≈18, C≈33, F≈52, fiber≈15, sugar≈10, about 672 kcal.
- HTTP 200, and all five fields are numbers.
- Each field falls roughly in band:

  | Field | Band (g) |
  |---|---|
  | protein | 8–35 |
  | carbs | 15–70 |
  | fat | 25–90 |
  | fiber | 6–30 |
  | sugar | 2–25 |

- Fat is the largest of P/C/F.
- `4P+4C+9F` is between 350 and 1300 kcal.
- `uncertainty_note` names some of the foods and mentions portion size or scale. "Some reference",
  because of the cutlery, is also fine.

**Negative checks.**
1. The same call without `Authorization` should return 401.
2. A non-food photo should return 200 with five nulls and a populated note.

**Variance.** Run the main call 3 times.
- If any run returns all-null on the real plate, find the `estimate rejected:` line in the
  dashboard's function logs.
- A `fiber_g + sugar_g exceeds carbs_g` rejection means the prompt needs tightening. Fix the prompt;
  don't loosen the check.
- If the numbers are garbage, iterate on `SYSTEM_PROMPT` and redeploy **before** building the UI.
- Record the outputs in the commit message or PROGRESS.md.

### Step 8. Client API (`web/Services/WorkflowApiClient.cs`)

**8a. `WorkflowSummary`.**
```csharp
public record WorkflowSummary(string Id, string Name, string ItemLabel, string? ItemLabelPlural, bool GroupItemsByDate);
```
- In both `GetWorkflowsAsync` (line 53) and `GetWorkflowAsync` (line 66), change
  `select=id,name,item_label` to `select=id,name,item_label,item_label_plural,group_items_by_date`.
- Construct the record with `r["item_label_plural"]?.GetValue<string>()` and
  `r["group_items_by_date"]?.GetValue<bool>() ?? false`.
- Nothing else constructs `WorkflowSummary`.

**8b. `FoodScanResult`.** Place it next to the other records.
```csharp
// scan-plate's response (2026-11-11): all five grams fields are either all numbers or all null
// (the function rejects a partial/invalid/implausible estimate wholesale); UncertaintyNote can be
// present either way -- on a failed scan it's the model's reason (e.g. no food visible).
public record FoodScanResult(double? ProteinG, double? CarbsG, double? FatG, double? FiberG, double? SugarG, string? UncertaintyNote)
{
    public bool HasEstimate => ProteinG is not null && CarbsG is not null && FatG is not null && FiberG is not null && SugarG is not null;
}
```

**8c. `CreateItemInStageAsync`.** Place it right after `MoveStageAsync`.
```csharp
// Same create_item RPC the agent's create_item tool calls, but the explicit-stage overload
// (p_stage_id) -- used directly by the "+ New <item>" stage-chooser for workflows with no
// is_initial stage, where the user has already picked the stage by tapping it, so there's
// nothing for a model to infer (2026-11-11). Returns the new item's id so the caller can open
// exactly that item rather than guessing it's the newest one.
public async Task<string> CreateItemInStageAsync(string workflowId, string stageId)
{
    var req = await NewRequestAsync(HttpMethod.Post, "/rest/v1/rpc/create_item");
    req.Content = JsonContent.Create(new JsonObject
    {
        ["p_workflow_id"] = workflowId,
        ["p_stage_id"] = stageId,
        ["p_data"] = new JsonObject(),
    });
    var res = await _http.SendAsync(req);
    var text = await res.Content.ReadAsStringAsync();
    if (!res.IsSuccessStatusCode)
        throw new HttpRequestException($"create_item failed ({(int)res.StatusCode}): {text}");
    var node = JsonNode.Parse(text)!;
    var row = node is JsonArray arr ? arr[0]! : node;
    return row["id"]!.GetValue<string>();
}
```
- PostgREST resolves overloads by the named keys. `{p_workflow_id, p_stage_id, p_data}` matches only
  the 3-arg function.
- A non-setof composite return comes back as an object. The array branch is defensive.

**8d. `ScanFoodPhotoAsync`.** Place it right after `ScanVinAsync`.
```csharp
// Same one-shot pattern as ScanVinAsync -- the photo is read once by scan-plate and discarded,
// never stored or added to any conversation history (2026-11-11).
public async Task<FoodScanResult> ScanFoodPhotoAsync(string imageBase64, string mediaType)
{
    var req = await NewRequestAsync(HttpMethod.Post, "/functions/v1/scan-plate");
    req.Content = JsonContent.Create(new JsonObject
    {
        ["image_base64"] = imageBase64,
        ["media_type"] = mediaType,
    });
    var res = await _http.SendAsync(req);
    var text = await res.Content.ReadAsStringAsync();
    if (!res.IsSuccessStatusCode)
        throw new HttpRequestException($"scan-plate failed ({(int)res.StatusCode}): {text}");
    var json = JsonNode.Parse(text)!.AsObject();
    return new FoodScanResult(
        json["protein_g"]?.GetValue<double>(),
        json["carbs_g"]?.GetValue<double>(),
        json["fat_g"]?.GetValue<double>(),
        json["fiber_g"]?.GetValue<double>(),
        json["sugar_g"]?.GetValue<double>(),
        json["uncertainty_note"]?.GetValue<string>());
}
```

### Step 9. `web/Pages/WorkflowDetail.razor`

How to apply these edits:
- Edits are in file order. Line numbers are against the file **before Step 9 starts**, and they drift
  after 9d's insertion. Locate each edit by its quoted "before" text.
- The quoted "before" text is unique in the file, with one exception. The `Job #@JobNumber(item)
  &mdash; @when...` line appears twice (lines 108 and 173), and the two copies differ only in
  indentation (28 vs 24 spaces). 9e and 9g say which is which.
- Line swaps are shown as whole-line before/after. Wraps show the full before/after block.

**9a. Header back link in the stage view (line 22).** This is D13. Before:
```razor
                <FluentLink @onclick="BackToItem" Class="back-link">&larr; Stages</FluentLink>
```
After:
```razor
                @if (AllStagesTerminal)
                {
                    @* No pipeline overview for an all-terminal workflow (D13, 2026-11-11) -- an
                       item opens straight into its own stage, so "back" goes to the list. *@
                    <FluentLink @onclick="BackToList" Class="back-link">&larr; @ItemLabelPlural</FluentLink>
                }
                else
                {
                    <FluentLink @onclick="BackToItem" Class="back-link">&larr; Stages</FluentLink>
                }
```

**9b. Header Chat button (line 42).** Replace `@if (_newJobMode || _selectedItem is not null)` with
`@if (ChatAvailable)`. This is the first of two occurrences of that condition; the other is 9k. Also
append to the comment above it: "...or hidden on the stage-chooser New screen, where there's nothing
for chat to do (2026-11-11)."

**9c. Stage-view heading (line 56).** Before:
```razor
        <h1 style="overflow-wrap:anywhere; word-break:break-word;">Job #@JobNumber(_selectedItem) &mdash; @StageTitle(_selectedStageId)</h1>
```
After:
```razor
        <h1 style="overflow-wrap:anywhere; word-break:break-word;">@ItemLabelSingular #@JobNumber(_selectedItem) &mdash; @StageTitle(_selectedStageId)</h1>
```

**9d. Scan-plate block.** Insert it right after the Scan VIN block closes (after line 90) and before
the `scheduled_at` block:
```razor
@if (_stages.FirstOrDefault(s => s.Id == _selectedStageId)?.Checklist.Contains("protein_g") == true)
{
    @* Same camera-capture-as-button pattern as Scan VIN above (2026-11-11), gated on a meal
       stage's own checklist field the same way -- nutrition_goal's keys are *_goal_g, so it
       never matches there. The note is shown, not discarded: it's the model's own flag for how
       far to trust these numbers. *@
    <div style="margin-bottom:12px;">
        <label for="plate-photo-input" class="fluent-button-like" style="display:inline-block; cursor:pointer;">
            <FluentButton Appearance="ButtonAppearance.Primary" Disabled="_scanningPlate">
                @(_scanningPlate ? "Scanning..." : "Scan Plate")
            </FluentButton>
        </label>
        <InputFile id="plate-photo-input" OnChange="OnFoodPhotoSelected" accept="image/*" capture="environment" style="display:none;" />
        @if (_plateScanNote is { } plateNote && plateNote.ItemId == _selectedItem.Id)
        {
            <p style="opacity:0.75;">Estimate note: @plateNote.Text</p>
        }
        @if (_plateScanError is not null)
        {
            <p style="opacity:0.75; color:var(--colorPaletteRedForeground1, #c00);">@_plateScanError</p>
        }
    </div>
}
```

**9e. Stage-view Other Appointments line (original line 108, the 28-space copy).** Before:
```razor
                            <div>Job #@JobNumber(item) &mdash; @when.ToString("MMM d, h:mm tt", System.Globalization.CultureInfo.InvariantCulture)</div>
```
After:
```razor
                            <div>@ItemLabelSingular #@JobNumber(item) &mdash; @when.ToString("MMM d, h:mm tt", System.Globalization.CultureInfo.InvariantCulture)</div>
```

**9f. Overview heading (original line 118).** Before: `        <h1>Job #@JobNumber(_selectedItem)</h1>`.
After: `        <h1>@ItemLabelSingular #@JobNumber(_selectedItem)</h1>`. Diet never reaches this page
after D13; the swap is for generality.

**9g. New-item screen (original lines 141–179).** Restructure it as below.
- The mechanic branch keeps the same content in the same order. Only the Other Appointments block
  moves inside the `initialStage` branch.
- Inside that moved block, apply the 9e swap to the **24-space** `Job #@JobNumber(item)` line
  (original line 173).
```razor
else if (_newJobMode)
{
    <h1>New @ItemLabelSingular</h1>
    @if (_stages.FirstOrDefault(s => s.IsInitial) is { } initialStage)
    {
        ...existing "Starts in" paragraph + checklist stack, unchanged...

        ...existing Other Appointments comment + block, moved inside this branch (only its
           "Job #" line swapped as above)...
    }
    else
    {
        @* No is_initial stage (2026-11-11, first needed by the Diet workflow): there's no single
           natural starting stage, so the user picks one and the item is created straight into
           it via create_item's explicit-stage overload -- a direct RPC, not chat, since the tap
           already says which stage; nothing for a model to guess. *@
        <p style="opacity:0.75;">Pick what kind of @ItemLabelSingular.ToLowerInvariant() this is:</p>
        <FluentStack Orientation="Orientation.Vertical" VerticalGap="6">
            @foreach (var stage in _stages.OrderBy(s => s.SequenceOrder ?? int.MaxValue))
            {
                <div style="margin-bottom:8px;">
                    <FluentButton Appearance="ButtonAppearance.Primary" Disabled="_creatingItem"
                                  @onclick="() => CreateItemInStage(stage.Id)">
                        @StageTitle(stage.Id)
                    </FluentButton>
                </div>
            }
        </FluentStack>
        @if (_createItemError is not null)
        {
            <p style="opacity:0.75; color:var(--colorPaletteRedForeground1, #c00);">@_createItemError</p>
        }
    }
}
```
The explicit `margin-bottom` follows the existing "VerticalGap isn't reliable" workaround.

**9h. List header and search box (original lines 183–193).** Leave `+ New @ItemLabelSingular`
unchanged.

Show/Hide closed, before (lines 184–186):
```razor
        <FluentLink @onclick="@(() => _showClosed = !_showClosed)" Class="back-link" Style="margin-left:16px;">
            @(_showClosed ? "Hide closed" : "Show closed")
        </FluentLink>
```
After:
```razor
        @if (!AllStagesTerminal)
        {
            <FluentLink @onclick="@(() => _showClosed = !_showClosed)" Class="back-link" Style="margin-left:16px;">
                @(_showClosed ? "Hide closed" : "Show closed")
            </FluentLink>
        }
```

Search placeholder, before (line 193):
```razor
            <FluentTextInput @bind-Value="_searchQuery" Placeholder="Search jobs..." Style="flex:1;"
```
After:
```razor
            <FluentTextInput @bind-Value="_searchQuery" Placeholder="@($"Search {ItemLabelPlural.ToLowerInvariant()}...")" Style="flex:1;"
```

**9i. Search result card (original lines 211–216).** Keep `var item = new ItemSummary(...)` above
the branch, and wrap the existing `FluentCard` like this (D6):
```razor
@if (_workflow?.GroupItemsByDate == true)
{
    @* Same card as the grouped list (D6) -- ItemTitle would be an id fragment for entries with
       no text field. Search stays flat, so the line carries the date too (2026-11-11). *@
    <FluentCard Class="clickable-card" style="padding:14px; max-width:100%; box-sizing:border-box; border-radius:var(--app-radius);" @onclick="() => SelectItem(item)">
        <strong style="color:var(--app-accent);">#@result.JobNumber @StageTitle(item.StageId) &rarr;</strong>
        <div style="opacity:0.7; margin-top:2px;">@item.CreatedAt.ToLocalTime().ToString("ddd, MMM d, h:mm tt", System.Globalization.CultureInfo.InvariantCulture)</div>
    </FluentCard>
}
else
{
    ...existing search FluentCard, unchanged...
}
```

**9j. Plain list (original lines 220–233).** Change the `else` into
`else if (_workflow?.GroupItemsByDate == true) { grouped } else { existing flat list, untouched }`:
```razor
else if (_workflow?.GroupItemsByDate == true)
{
    @* Log-style workflows (e.g. Diet, 2026-11-11) read as a diary: one heading per local
       calendar day, newest day first, entries within a day in the order they happened. Pure
       display grouping off each item's own created_at -- nothing links items together. The
       card shows stage + time instead of ItemTitle, since entries like these have no text
       field to title them by. *@
    @foreach (var day in VisibleItems().GroupBy(i => i.CreatedAt.ToLocalTime().Date).OrderByDescending(g => g.Key))
    {
        <h2>@day.Key.ToString("dddd, MMMM d, yyyy", System.Globalization.CultureInfo.InvariantCulture)</h2>
        <FluentStack Orientation="Orientation.Vertical" VerticalGap="8" Style="margin-top:8px;">
            @foreach (var item in day.OrderBy(i => i.CreatedAt))
            {
                <FluentCard Class="clickable-card" style="padding:14px; max-width:100%; box-sizing:border-box; border-radius:var(--app-radius);" @onclick="() => SelectItem(item)">
                    <strong style="color:var(--app-accent);">#@JobNumber(item) @StageTitle(item.StageId) &rarr;</strong>
                    <div style="opacity:0.7; margin-top:2px;">@item.CreatedAt.ToLocalTime().ToString("h:mm tt", System.Globalization.CultureInfo.InvariantCulture)</div>
                </FluentCard>
            }
        </FluentStack>
    }
}
```

**9k. Chat section (original line 256).** Replace `@if (_newJobMode || _selectedItem is not null)`
with `@if (ChatAvailable)`. This is the second occurrence; 9b was the first.

**9l. `@code` members.**
- **`ItemLabelPlural`** (line 396):
  ```csharp
  // item_label_plural (2026-11-11) for labels where + "s" is wrong ("entry" -> "entries");
  // null keeps the original + "s" fallback, so job/jobs and ticket/tickets are unchanged.
  private string ItemLabelPlural =>
      string.IsNullOrEmpty(_workflow?.ItemLabelPlural) ? ItemLabelSingular + "s" :
      char.ToUpperInvariant(_workflow.ItemLabelPlural[0]) + _workflow.ItemLabelPlural[1..];
  ```
- **`ChatAvailable`** goes next to `_newJobMode`:
  ```csharp
  // Chat creates items only via the agent's create_item tool, which lands in the is_initial
  // stage -- in a workflow with none, New mode is the stage-chooser instead and chat there
  // could only ever fail, so it's hidden until an item actually exists (2026-11-11). Once an
  // item is open, chat stays (corrections via update_data); a create request there gets a
  // plain "use + New" answer from agent-loop's own create_item guard.
  private bool ChatAvailable =>
      _selectedItem is not null || (_newJobMode && _stages?.Any(s => s.IsInitial) == true);
  ```
- **`AllStagesTerminal`** goes above `VisibleItems`, and `VisibleItems` gets a new first condition:
  ```csharp
  // Every stage terminal (e.g. Diet, 2026-11-11) means items never move and nothing is ever
  // "open" -- so there's nothing to hide as closed, no stage to "complete" into the next one,
  // and no pipeline progress for the overview page to show (see SelectItem).
  private bool AllStagesTerminal => _stages is { Count: > 0 } && _stages.All(s => s.IsTerminal);

  private IEnumerable<ItemSummary> VisibleItems() =>
      _showClosed || AllStagesTerminal
          ? _items!
          : _items!.Where(i => _stages!.FirstOrDefault(s => s.Id == i.StageId)?.IsTerminal != true);
  ```
- **`ItemTitle` fallback** (line 520): change `ItemLabelPlural.TrimEnd('s')` to `ItemLabelSingular`.
- **`SelectItem`** (lines 633–639), D13: replace `_selectedStageId = null;` with
  ```csharp
        // All-terminal workflows (D13, 2026-11-11) skip the stage overview: it exists to show
        // pipeline progress, and there every meal card would show the same shared-key ticks --
        // and drilling into a non-current card would let Scan Plate/chat write onto this item.
        _selectedStageId = AllStagesTerminal ? item.StageId : null;
  ```
- **`DoneNextStage`**: make `if (AllStagesTerminal) return null;` the first line. Extend its comment
  with "...or every stage in the workflow is terminal (2026-11-11)".
- **`CreateItemInStage`** and its state go next to `StartNewJob`:
  ```csharp
  private bool _creatingItem;
  private string? _createItemError;

  // Stage-chooser tap (2026-11-11): creates the item directly via the explicit-stage
  // create_item overload, then drops straight into that item's stage view -- same landing spot
  // as Send()'s new-job auto-drill, but keyed on the returned id instead of "newest item".
  private async Task CreateItemInStage(string stageId)
  {
      if (_creatingItem) return;
      _creatingItem = true;
      _createItemError = null;
      try
      {
          var newId = await Api.CreateItemInStageAsync(WorkflowId, stageId);
          _items = await Api.GetItemsAsync(WorkflowId);
          _newJobMode = false;
          _selectedItem = _items.FirstOrDefault(i => i.Id == newId);
          _selectedStageId = _selectedItem?.StageId;
          if (_selectedItem is not null)
              await LoadFieldStageMap(_selectedItem.Id);
      }
      catch (Exception ex)
      {
          _createItemError = $"Couldn't create {ItemLabelSingular.ToLowerInvariant()}: {ex.Message}";
      }
      finally
      {
          _creatingItem = false;
      }
  }
  ```
  `CancelNewJob` also clears `_createItemError`, which turns it into a two-statement block body.
- **`OnFoodPhotoSelected`** and its state go right after `OnVinPhotoSelected`:
  ```csharp
  private bool _scanningPlate;
  private string? _plateScanError;
  // Tagged with the item it was produced for, so moving to another entry doesn't show the
  // previous plate's caveat next to different numbers (2026-11-11).
  private (string ItemId, string Text)? _plateScanNote;

  // Same resize-then-send-once path as OnVinPhotoSelected; writes the five estimates through
  // the direct UpdateDataAsync wrapper into the entry that was open when the photo was taken,
  // never via chat (2026-11-11).
  private async Task OnFoodPhotoSelected(InputFileChangeEventArgs e)
  {
      if (_scanningPlate || _selectedItem is null) return;
      _scanningPlate = true;
      _plateScanError = null;
      _plateScanNote = null;
      var itemId = _selectedItem.Id;
      try
      {
          var resized = await e.File.RequestImageFileAsync("image/jpeg", 1600, 1600);
          using var stream = resized.OpenReadStream(maxAllowedSize: 5 * 1024 * 1024);
          using var ms = new MemoryStream();
          await stream.CopyToAsync(ms);
          var base64 = Convert.ToBase64String(ms.ToArray());

          var scan = await Api.ScanFoodPhotoAsync(base64, "image/jpeg");
          if (!scan.HasEstimate)
          {
              _plateScanError = "Couldn't estimate nutrition from that photo -- try again with the whole plate in frame and in focus."
                  + (scan.UncertaintyNote is { } why ? $" ({why})" : "");
              return;
          }

          await Api.UpdateDataAsync(itemId, new JsonObject
          {
              ["protein_g"] = scan.ProteinG,
              ["carbs_g"] = scan.CarbsG,
              ["fat_g"] = scan.FatG,
              ["fiber_g"] = scan.FiberG,
              ["sugar_g"] = scan.SugarG,
          });
          if (scan.UncertaintyNote is { } scanNote)
              _plateScanNote = (itemId, scanNote);
          _items = await Api.GetItemsAsync(WorkflowId);
          // Only refresh the open view if the user is still on the scanned entry -- if they
          // navigated away mid-scan, the write still landed on the right item; don't pull them back.
          if (_selectedItem?.Id == itemId)
          {
              _selectedItem = _items.FirstOrDefault(i => i.Id == itemId);
              if (_selectedItem is not null)
                  await LoadFieldStageMap(_selectedItem.Id);
          }
      }
      catch (Exception ex)
      {
          _plateScanError = $"Scan failed: {ex.Message}";
      }
      finally
      {
          _scanningPlate = false;
      }
  }
  ```
  Capturing `itemId` before the awaits is a deliberate improvement on the VIN handler.

Post-edit check: `grep -n 'Job #' web/Pages/WorkflowDetail.razor` should match only the C# comment
near the original line 403 ("a request about Job #9...").

### Step 10. Build

```bash
cd /home/mmcbride/micah/claude/workflow-app
dotnet build web/WorkflowApp.Web.csproj
```

It must build without new errors. Fix any warnings the edits introduce, unless they're the same kind
as an existing pattern, e.g. the nullable warning on `_workflow.` after `IsNullOrEmpty`.

### Step 11. UI verification

Ordering:
- The desktop checks can run against a local `dotnet run` (it talks to the dev backend, where both
  functions are already deployed).
- **The phone/camera checks need the GitHub Pages deploy**, which means pushing `web/**` to `main`.
  Get the user's go-ahead to push (Step 12) before running them.

**Diet:**
1. The Workflows list shows "Diet".
   - Opening it shows "Entries" and "+ New Entry", with **no** Show/Hide closed toggle.
   - With no entries, the list is empty with no error.
   - The placeholder reads "Search entries...".
2. "+ New Entry" shows "New Entry" and 5 buttons in order: Nutrition goal, Breakfast, Lunch, Dinner,
   Snack. There is **no** Other Appointments, and **no** chat box or header Chat button.
3. Tap Breakfast. You land on "Entry #1 — Breakfast":
   - 6 checklist rows, with **no `*`**;
   - a **Scan Plate** button;
   - **no Complete Stage** button;
   - a header back link that reads "← Entries".
4. "← Entries", then tap the entry card. It opens **directly** in "Entry #1 — Breakfast", with no
   Stages overview page (D13).
5. (Phone) Scan Plate on a real plate.
   - Five values appear as checked fields, with "Estimate note: ..." below.
   - Scanning a non-food photo shows the red "Couldn't estimate..." message and writes nothing.
6. In chat, type "bump protein to 30g". `protein_g` updates, and there's no offer to move the entry.
7. **Chat create guard (D12).** On the open entry, type "add a lunch entry".
   - **Pass:** an **Agent** row in plain language pointing to "+ New".
   - **Fail:** the text `is_initial`, `P0001`, `/rpc/` or a uuid appears, or an **Error** row appears,
     or a new item shows up in the list.
   - Optional: run
     `supabase db query --linked "select created_at, error_message from agent_events where event_type = 'error' order by created_at desc limit 3;"`.
     A fresh `create_item: Error: this workflow has no starting stage...` row means the guard fired.
     No new row means the description made the model decline. Either passes.
8. Back on Entries:
   - Today's heading shows "#1 Breakfast →" with a time.
   - Add two Snacks. They appear under the same day, in creation order.
   - Add a Nutrition goal. It shows the 5 `*_goal_g` fields, **no** Scan Plate and no `*`.
9. Search "breakfast". The results are a flat list whose cards read "#1 Breakfast →" with a
   "Wed, Nov 11, 8:14 AM"-style line, not "Entry 3fa2b1c0" / "Stage: Breakfast". Tapping a result
   opens the stage view directly.

**Mechanic regression (Joe's Auto Repair).** It must look exactly as it does today:
- "Jobs", "+ New Job" and the Show closed toggle are present, and the placeholder reads
  "Search jobs...".
- The flat list and search results show `#N Title` / `Stage: X`, and closed jobs are hidden by
  default.
- **Tapping a job opens the Stages overview page**, and a stage view's back link reads "← Stages"
  (the D13 regression check).
- "+ New Job" shows the Intake checklist, Other Appointments ("Job #N — ...") and chat.
  **Creating a job via chat still works and auto-drills into Intake** (the guard regression check).
- The headings read "Job #N". Diagnosis shows Scan VIN and **not** Scan Plate.
- A job at payment_receipt_submitted with payment_method filled still offers **Complete Stage**.
- The `*` markers are unchanged.

### Step 12. Commit, push, PROGRESS.md

- **Commits.** Use whichever split the user prefers:
  - two commits: (a) migrations + scan-plate + agent-loop guard, (b) the web app;
  - or a single commit.

  Include `plans/diet-workflow/*.md`. Leave `test-plate.jpg` out unless the user says otherwise.
  Mention the "scope stage-title matches by workflow_id from now on" rule in the migrations commit.
- **Push only when the user asks.** Pushing to `main` triggers `deploy-pages.yml` (`web/**`). The
  functions were already deployed by hand.
- **PROGRESS.md.** Add one lean line covering:
  - the Diet workflow on dev;
  - the generic stage-chooser;
  - `item_label_plural` / `group_items_by_date`;
  - scan-plate with validation;
  - the create_item guard;
  - the all-terminal skip-overview behavior;
  - the Step 7 results in one line.

## 4. Assumptions not verified

- PostgREST returns a single object for a non-setof composite RPC. The wrapper also handles an array.
- `TimeZoneInfo.Local` in Blazor WASM is the browser's zone. The existing note timestamps already
  rely on this.
- The label-wrapped `FluentButton` file picker works on the phone. Scan Plate inherits whatever Scan
  VIN does.
- `claude-sonnet-5-5` follows the JSON-only instruction and the carb-subset constraint. If it
  doesn't, the user sees "couldn't estimate", not bad data.
- `functions deploy --use-api` bundles `./validate.ts`. Step 5 has the fallback.
- The deployed agent-loop matches repo HEAD before Step 6b.
- Gateway `verify_jwt` behavior on OPTIONS matches scan-vin's.

## 5. Risks and edge cases

- **Inherited cost exposure.** scan-plate, like scan-vin, relies only on gateway JWT verification.
  Tightening both (an account-membership check) is a separate follow-up.
- **Validation false rejects and accepts.**
  - False rejects: a whole pizza over 3000 kcal, black coffee under 10 kcal, or a model that
    double-counts sugar inside fiber. Rejections are logged with their reason. Fall back to chat.
  - False accepts: a plausible-but-wrong estimate, e.g. a 2× portion error. The uncertainty note and
    chat corrections cover that.
- **Rescanning overwrites** all five values. Seconds go in their own snack entry.
- **Chat can't create Diet entries.** After D12 it gets a clean "use + New" answer. That's intended;
  the `stage_id`-on-`create_item` follow-up would change it.
  - The guard message says "+ New", which is web-UI wording. `mcp-server`'s own `create_item` (a
    testing tool) still surfaces the raw RPC error for Diet. That's not user-facing, so it's left
    alone.
- **Chat can move a Diet entry between meal stages** on an explicit request ("that was actually
  lunch"). `is_terminal` doesn't block `move_stage`.
  - That's a reasonable correction path. The shared macro keys stay on the item, so nothing is lost.
  - The UI never offers a move, and the agent's next-stage nudge is suppressed at terminal stages.
- **`AllStagesTerminal` now drives three behaviors**: no closed filter, no Complete Stage, and no
  overview page.
  - All three follow from "items never move", so the derivation is sound for today's shapes.
  - A future workflow with only terminal *outcome* stages (resolved / dismissed / duplicate) would
    also match. It would lose the closed filter and the overview.
  - The fix then is an explicit per-workflow flag, as D1 and D3 do for their own concerns. Not now,
    since it would be a knob with no user.
- **Diet entries have no job-level notes page (D13).** Notes made on the stage view are stage-tagged
  and shown there.
- **No back-dating.** An entry's day is its `created_at` in the browser's local time. The future
  reporting tool must use the same timezone convention (D4).
- **List scale.** Diet adds about 4–6 items/day. `GetItemsAsync` loads everything, and `JobNumber()`
  re-sorts per card. This is fine for weeks and slow after many months. It's pre-existing, and
  pagination or a memoized number map is the follow-up.
- **agent-loop's prompt says "mechanic-shop"**, and its rules talk about "jobs". Diet chat works
  because the stages JSON and the terminal-stage rule are in the prompt. The wording is out of scope.
- **The `create_item` description change** alters the static tools prefix once for every workflow.
  Stale thinking blocks in in-flight chats are dropped by the existing `drop_block` setting. This is
  the same as any tool-description deploy.
- **Deploy window** (Step 3): dev shows Diet with the old client until the web push. Dev only, no
  other users.
- **Rollback.**
  - Web: revert the web commit. The old client ignores the new columns.
  - scan-plate: `supabase functions delete scan-plate --project-ref utwyvtbzesswpoihmlic`.
  - agent-loop: restore the previous file and redeploy. The guard is also safe to leave in place.
  - Data: Diet rows can stay. Removing them needs service-role SQL, since there are no DELETE
    policies.
  - The new `workflows` columns are additive and safe to drop once the old client is back.

## 6. Out of scope (deliberate)

- Day-level parent items or linking between meals.
- Totals, rollups, goal-vs-actual, reporting.
- "Goal in effect on date X" resolution.
- A correction UI for scanned values. Chat covers it.
- Persisting the uncertainty note.
- Agent-loop changes beyond D12: prompt wording, and creating into a chosen stage from chat.
- Back-dating entries.
- A shared request-validation module for edge functions.
- Porting any of this to prod.

---

## Architect adjudication

**Inputs.**
- `round-2-draft.md` and `round-2-review-notes.md`.
- `round-2-sanity-check.md` was **not present on disk**. Its items are adjudicated below as relayed
  in the orchestrator's brief: the missing `deno check` on scan-plate, and D12's overstated
  justification.
- I checked every claim below against the live `WorkflowDetail.razor`, `WorkflowApiClient.cs`,
  `agent-loop/index.ts`, `scan-vin/index.ts`, `mcp-server/index.ts`, and the phase0/1/1b/3/4b and
  `20261020200000` migrations.
- No disputed claim needed an external source. Every disagreement was settled by reading this repo.

### Reviewer and sanity-check findings

| # | Finding | Ruling | Action |
|---|---|---|---|
| 1 | Step 7's photo path is session-scoped and won't be there for a later implementer (plan-reviewer) | **Valid, folded in** | Copy to `plans/diet-workflow/test-plate.jpg` before implementation; not committed by default (public repo, personal photo); explicit fallback to "photograph your own plate and derive your own bands" |
| 2 | Step 9's "quoted text is unique" claim is false for the duplicated Other Appointments line (plan-reviewer) | **Valid, folded in** | The Step 9 preamble now names the one exception and says how 9e and 9g tell the copies apart |
| 3 | 9f's Show-closed wrap was prose-only, breaking the step's own before/after convention (plan-reviewer) | **Valid, folded in** | 9h now has the exact before/after block, and the placeholder line too |
| 4 | Step 4c's "scan-vin lines 30–59" is off by one (plan-reviewer) | **Invalid** | Lines 30–59 are exactly the elided blocks, from the `OPTIONS` check (30) to the required-fields 400 (59). Line 29 is the `Deno.serve(` opener, which the code block already shows. The citation stays, with its range spelled out |
| 5 | Missing `deno check` on scan-plate/index.ts (sanity-check, relayed) | **Valid, folded in** | New Step 4d runs it next to the unit test, gating Step 5, matching what Step 6b already does for agent-loop |
| 6 | D12 overstates the case against omitting `create_item` from `tools` (sanity-check, relayed) | **Valid on the reasoning, decision unchanged** | The "prefix varies per workflow" argument is weak, because the system prompt already embeds per-workflow stages. The "prior tool_use in history" argument is also moot, because conversations are per-item within one workflow. D12 now rests on the real reasons: `TOOLS` stays a single static constant (the existing pattern), the message is deterministic and testable, and the guard holds even if the model ignores the description |

### Item the draft explicitly left for the architect

- **Diet entries opening the generic Stages overview** (draft Risks: "Flagged for the architect to
  decide"). **Decided: fix now (D13).**
- The draft treated it as cosmetic. It isn't. On the overview, tapping a *non-current* meal card
  shows Scan Plate and chat, and both write onto the open entry. A breakfast entry can be "scanned
  from the Lunch card" with no cue that it's still breakfast.
- The fix is about 12 lines: `SelectItem` plus the header back link. It's gated on the existing
  `AllStagesTerminal`, inert for the mechanic, and covered by a new Diet check and a new mechanic
  regression check in Step 11.

### Architectural fit (systemic review)

- **The generic engine is used, not bent.** Diet is pure content: one workflow row and five stage
  rows. The schema changes are two additive display columns on `workflows`, both following the
  existing `item_label` precedent (per-workflow display settings live on `workflows`). No
  Diet-specific branches exist anywhere in code. Every UI branch keys off a generic property: no
  initial stage, all stages terminal, `group_items_by_date`, a checklist containing `protein_g`.
  The last one is the same gating idiom Scan VIN uses with `vin`.
- **Direct-RPC-wrapper pattern.** `CreateItemInStageAsync` and the scan → `UpdateDataAsync` write
  match `MoveStageAsync`, `UpdateDataAsync` and `ScanVinAsync` exactly: a deterministic UI action,
  with no model in the loop. One systemic consequence the draft understated: this promotes the
  3-arg `create_item` overload from an accidental survivor (`20261020200000` calls it the "old"
  overload) to a supported API. Migration A's comment now says so, including its one behavioral
  difference (no `p_data` in the event).
- **Agent loop.** The D12 guard uses the established precondition-throw idiom and the existing
  error-relay path. `TOOLS` stays static. The fit is clean.
- **scan-vin template.** scan-plate is a faithful copy with one justified deviation, a separate
  `validate.ts`, done for testability. That's the first edge-function unit test in the repo. It
  isn't a new runtime dependency or shared module, so scan-vin stays untouched.
- **Correctness fix in the scan handler.** The draft's `OnFoodPhotoSelected` re-selected the
  scanned item after the awaits regardless of where the user had gone. That could pull a user who
  navigated to the list mid-scan back into the overview or stage state with a mismatched
  `_selectedStageId`. It now refreshes the view only if the user is still on that item. Also, the
  pattern variable in the markup was renamed `note` → `plateNote` so it can't be confused with the
  `note` loop variable in the Notes section. They're in sibling scopes so it wouldn't fail to
  compile, but the rename removes the ambiguity.
- **Claims tightened.** "move_stage is never used in this workflow" was overstated: `is_terminal` is
  documented as a hint, not a block, and chat can still move an entry on request. The migration
  comment and Risks now describe that as an acceptable correction path.
- **Process.** Step 11's phone checks can't run before the Pages deploy, and pushing needs the
  user's go-ahead. That ordering is now explicit. The Step 3 → Step 12 window where dev shows Diet
  with the old client is now named as an accepted risk.
- **Nothing found that fights the architecture.** The one growing pressure point is
  `AllStagesTerminal` now carrying three behaviors. It's documented, it's sound for today's shapes,
  and the off-ramp (an explicit flag) is named.

### Sign-off

**`approved-with-changes`.** Changes from round 2:
- D13 skip-overview: Step 9a and the `SelectItem` change in 9l, plus Step 11 items 3, 4 and 9 and a
  mechanic regression check.
- The scan-handler re-select fix.
- `deno check` on scan-plate (Step 4d).
- Durable test-photo path with a fallback (Step 7).
- Exact before/after for the Show-closed wrap (9h).
- Honest D12 justification.
- Migration A and B comment corrections (the 3-arg overload is now a supported API; chat can move
  entries).
- Explicit push-before-phone-test ordering and the deploy-window note.
- Step 9 renumbered a–l in file order.

No further review round is needed. The plan is ready to implement.
