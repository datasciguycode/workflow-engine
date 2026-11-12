# Diet workflow: implementation plan (round 1 draft)

Dev only: repo `/home/mmcbride/micah/claude/workflow-app`, Supabase project `workflow-engine-test`
(ref `utwyvtbzesswpoihmlic`, already the linked project per `supabase/.temp/project-ref`). Nothing
here touches `/home/mmcbride/micah/claude/workflow-app-prod` or its project.

## 0. Ground truth checked before writing (read-only, 2026-11-11)

- **Live dev workflows.** A read-only `supabase db query --linked` returned four workflows:
  - "Acct 1 workflow" and "Acct 2 workflow" (isolation fixtures).
  - "Feature Pipeline" (`ticket`), with no checklists.
  - "Joe's Auto Repair": id `33333333-3333-3333-3333-333333333330`, account
    `11111111-1111-1111-1111-111111111111`, `item_label = 'job'`.

  There is no "Diet" yet. Mechanic stages: intake (is_initial) → scheduling → diagnosis → estimated
  → approval → in_progress → invoicing → **payment_receipt_submitted (seq 8, is_terminal)** →
  **closed (seq null, is_terminal, no checklist)**. Every mechanic stage that has a checklist has at
  least one required (non-optional) field.
- **Both `create_item` overloads exist on dev**, and `authenticated` has EXECUTE on both:
  `create_item(uuid,jsonb)` and `create_item(uuid,uuid,jsonb)`. The 3-arg one was dropped in
  phase1, then re-created by phase4b's `create or replace`. It inserts the item into `p_stage_id`
  and logs `item.created` with that `stage_id`. It does **not** copy `p_data` into the event, which
  doesn't matter here because we pass `{}`.
- **`workflows` has only `item_label`.** There is no plural column. `ItemLabelPlural` in
  `WorkflowDetail.razor` is computed as `ItemLabelSingular + "s"`, so `entry` would display as
  **"Entrys"**. See D2.
- **Auth.** `AuthState` keeps the session in localStorage under
  `workflow-app.auth-session.utwyvtbzesswpoihmlic` as JSON
  `{access_token, refresh_token, expires_at, email}`. This matters for the test token (Step 7).
- **Tooling.**
  - Supabase CLI is v2.120.0. Don't upgrade, for the same reason as the prod plan.
  - Docker is installed, but the prod plan standardized on `functions deploy --use-api`.
  - `python3`, `curl` and `base64` are present. `jq` and ImageMagick are **not**.
  - The test photo is a 2016x1512 JPEG of 1.29 MB, about 1.7 MB as base64. That's under the
    Anthropic image limit, so it can be sent as-is without resizing.

## 1. Problems the settled design exposes in existing generic code (must fix, or Diet breaks)

These came out of reading `WorkflowDetail.razor` against the design. They aren't redesigns. Each is
the minimum needed for "all 5 stages terminal, none initial" to behave.

1. **The whole Diet list would be empty by default.** `VisibleItems()` hides every item in an
   `is_terminal` stage unless "Show closed" is toggled, and every Diet stage is terminal.
2. **"Complete Stage" would appear on every meal and move it to the next meal.** `DoneNextStage()`
   computes `required = Checklist.Except(OptionalChecklist)`. That is empty for Diet, so `.All(...)`
   is vacuously true and `NextStage` returns the next stage by `sequence_order`. For example,
   breakfast would get a button that `move_stage`s it to lunch. That violates "move_stage is never
   used in this workflow".
   - I rejected gating on `stage.IsTerminal`. The mechanic's `payment_receipt_submitted` is
     terminal and today correctly offers Complete Stage → `closed`, so that gate would visibly break
     the mechanic flow.
3. **The New-Job screen and chat assume an initial stage.**
   - "Other Appointments" renders unconditionally in `_newJobMode`, so it would show "No upcoming
     appointments scheduled." on the Diet chooser.
   - The chat box (and header Chat button) also renders in `_newJobMode`. In a workflow with no
     initial stage, the agent's `create_item` tool calls the 2-arg overload, which raises
     `workflow % has no is_initial stage`. So chat on the chooser screen can only ever produce an
     error.
4. **Hardcoded "Job" text that Diet would show.**
   - The `<h1>Job #N — Stage</h1>` and `<h1>Job #N</h1>` headings.
   - The `Search jobs...` placeholder.
   - `ItemTitle`'s fallback `ItemLabelPlural.TrimEnd('s')`, which turns "Entries" into "Entrie".

   Every one of these can switch to `ItemLabelSingular`/`ItemLabelPlural` with **zero visible
   change for the mechanic**, because "Job"/"Jobs" is exactly what its `item_label = 'job'`
   produces.

Fix for 1 and 2 is **one derived predicate**: `AllStagesTerminal`, meaning "every stage in this
workflow is an end state". In such a workflow nothing is ever "open", so there's nothing to hide as
"closed" and nothing to "complete". The mechanic and Feature Pipeline both have non-terminal
stages, so they are untouched.

## 2. Decisions (with rejected alternatives)

- **D1. The stage chooser is triggered by "no `is_initial` stage" and nothing else.** This is
  literally the condition under which the existing path can't work. The mechanic and Feature
  Pipeline have an initial stage and take the unchanged path.
  - Rejected: a new `workflows.choose_stage_on_create` flag. That's an extra knob with no current
    user. The "or more generally" case can add one later, and the chooser markup is already generic.
- **D2. Add a nullable `workflows.item_label_plural`.** `ItemLabelPlural` falls back to the current
  `+ "s"` behavior when it's null, so existing workflows are unchanged.
  - Rejected: picking a label that pluralizes with "s" (e.g. `log`). That dodges the brief's
    "entry"/"entries".
  - Rejected: an English pluralizer in C#. Over-engineered and wrong for irregulars.
- **D3. Date grouping is an explicit `workflows.group_items_by_date boolean not null default
  false`.** It is not derived from stage shape. Grouping by day is a display preference, and
  `AllStagesTerminal` is about lifecycle semantics. Coupling them would surprise the next workflow
  that wants one without the other. A single boolean, not a "view mode" enum or system: if a second
  mode ever appears, converting a boolean is trivial.
- **D4. Grouping uses the browser's local date** (`CreatedAt.ToLocalTime().Date`), not
  `created_at::date` (UTC).
  - A dinner logged at 8 pm US Central is already the next day in UTC.
  - Existing code already displays note timestamps via `ToLocalTime()`.
  - The (out-of-scope) reporting tool will need to adopt the same timezone convention, so this is
    noted under Risks.
- **D5. Ordering in grouped mode: days newest-first, entries within a day oldest-first.** Read top
  to bottom, it's today's log in eating order (breakfast before lunch), with history scrolling
  below.
- **D6. Grouped-mode card content: `#N {Stage} →` plus a time line**, instead of `#N {ItemTitle}` /
  `Stage: X`. Diet items have no string fields, so `ItemTitle` would fall back to
  "Entry 3fa2b1c0", which is meaningless. The flat (mechanic) card is untouched.
- **D7. Chat is hidden while the chooser is showing.** This uses a single `ChatAvailable` property
  that replaces the two duplicated `_newJobMode || _selectedItem is not null` conditions.
  `agent-loop` is not modified.
- **D8. The new client wrapper `CreateItemInStageAsync` calls the existing 3-arg `create_item` RPC
  directly.** It returns the new item's id, so the UI drills into exactly that item. It does not use
  the `_items[0]` "newest by updated_at" heuristic that `Send()` relies on. No migration touches
  `create_item`, but migration A re-issues its grant, idempotently, so the dependency is explicit in
  the repo rather than relying on default privileges.
- **D9. scan-plate is all-or-nothing.**
  - If all 5 numbers validate, return them.
  - Otherwise return all 5 as `null`, plus whatever `uncertainty_note` the model gave (e.g. why no
    food was found). This mirrors scan-vin returning `{vin: null}` with a 200 for "not readable".
  - Partial writes (e.g. 3 of 5 macros) are rejected because they'd look complete-ish in the
    checklist while being wrong.
- **D10. The uncertainty note is shown transiently, scoped to the item it was produced for**, like
  `_vinScanError`. It is not persisted. Persisting it, e.g. as an item note via `AddNoteAsync`, is a
  one-line follow-up if wanted, but it wasn't asked for.
- **D11. The scan prompt asks the note to briefly name what was identified first**, then the
  low-confidence factors. This lets the user catch a misidentification ("I see hummus", when it's
  peanut butter) and correct it via chat. It adds no new response fields.

## 3. Step-by-step

### Step 1. Migration A: generic workflow display columns

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

-- The stage-chooser on "+ New <item>" (2026-11-11) calls this explicit-stage overload directly
-- from the client for workflows with no is_initial stage. It's already executable by
-- authenticated on dev (re-created by 20261016130000 under default privileges, which grant
-- function execute broadly), but nothing in this repo says so explicitly -- the original
-- phase0 grant was on a function phase1 then dropped. Re-stated here so that dependency is
-- visible and survives a project whose defaults differ. Idempotent.
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
--   - EVERY stage is_terminal -- an entry never moves (move_stage is never used here). With all
--     stages terminal the UI treats nothing as "closed"/hideable and offers no Complete Stage
--     button, and agent-loop's prompt already skips its "move to the next stage?" nudge at a
--     terminal stage.
--   - checklist == optional_checklist on every stage -- nothing is ever required, so no
--     required-field "*" shows anywhere.
--   - sequence_order is display order only (stages are peers, not a pipeline); nothing gates on
--     it because enforce_stage_order stays false and no stage ever has a "next" to move to.
-- No day-level parent item: each meal/snack/goal change is its own item, related only by its own
-- created_at. A nutrition_goal entry is made only when targets change, not daily.

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
- `unique (workflow_id, title)` already exists (phase0), so `on conflict` is valid and makes the
  migration re-runnable.
- The stage titles are snake_case like every existing stage. `StageTitle()` renders
  `nutrition_goal` as "Nutrition goal".
- Earlier content migrations match stages **by title globally** (e.g. `where title = 'diagnosis'`).
  None of their titles collide with Diet's. From now on, any content migration matching on
  `breakfast`/`snack` etc. should also scope by `workflow_id`. This is worth a line in the commit
  message.

### Step 3. Push migrations to dev

```bash
cd /home/mmcbride/micah/claude/workflow-app
supabase db push --linked --dry-run      # expect exactly the two new files listed
supabase db push --linked
```

Then verify with a read-only query:

```bash
supabase db query --linked "select w.name, w.item_label, w.item_label_plural, w.group_items_by_date,
  s.title, s.sequence_order, s.is_initial, s.is_terminal, s.checklist = s.optional_checklist as all_optional
  from workflows w join stages s on s.workflow_id = w.id where w.name = 'Diet' order by s.sequence_order;"
```

Expect 5 rows, all `is_initial = false`, `is_terminal = true`, `all_optional = true`. Also check
`select name, item_label_plural, group_items_by_date from workflows` and confirm the other four
workflows show `null` / `false`.

### Step 4. New edge function `supabase/functions/scan-plate/index.ts`

Full logic follows. The header comment, imports, `MODEL`, CORS block, auth/body checks and error
shape are copied from scan-vin. The only changes are the prompt, `max_tokens`, and the
parse/validate block.

```ts
// Single-purpose nutrition estimate from a photo of a meal (2026-11-11). Same shape as scan-vin
// and for the same reasons deliberately NOT folded into agent-loop's tool-use chat loop: the
// photo never needs to enter conversation history (read once, discarded, never stored), no
// tool-calling is needed for a one-shot read, and a bad photo never costs a slot in the bounded
// chat turn loop or pollutes the stage's chat log. The client writes the five numbers itself via
// a direct update_data RPC call; corrections afterward ("bump protein to 30g") go through the
// normal chat/update_data path, not anything here.

import Anthropic from "npm:@anthropic-ai/sdk@0.32.1";

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

// Must match the meal stages' checklist keys exactly (see 20261111040000_add_diet_workflow.sql) --
// the client writes these keys straight into item data, and the checklist's done/not-done check
// looks for these exact keys.
const FIELDS = ["protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g"] as const;

// Sanity ceiling, same spirit as scan-vin's VIN regex: an estimate above this for any single
// nutrient on one plate is a parsing/model failure, not a meal -- reject rather than write it.
const MAX_GRAMS = 2000;

const SYSTEM_PROMPT =
  "You are given a photo of a single meal or snack. Identify the foods visible and estimate the " +
  "TOTAL of each nutrient across everything visible on the plate, in grams: protein_g, carbs_g " +
  "(total carbohydrate, including fiber and sugar), fat_g, fiber_g, sugar_g (total sugars). " +
  "Respond with ONLY one JSON object -- no markdown, no code fences, no other text -- with exactly " +
  'these keys: {"protein_g": number, "carbs_g": number, "fat_g": number, "fiber_g": number, ' +
  '"sugar_g": number, "uncertainty_note": string}. Each number must be a single plain JSON number ' +
  "(your best point estimate; no units, no ranges, no strings). uncertainty_note: one to three " +
  "short sentences -- first briefly name what you identified, then flag what makes this estimate " +
  "least reliable, e.g. no size/scale reference visible for judging portions, hidden ingredients " +
  "like cooking oil, butter, dressing or sauce that could add unlisted fat or sugar, or a mixed/" +
  "composite dish that is harder to break down than separate whole foods. If no food is clearly " +
  'visible, respond with exactly: {"not_food": true, "uncertainty_note": "<one sentence why>"}';

function round1(n: number) {
  return Math.round(n * 10) / 10;
}

// Model output is checked, never trusted blindly: tolerate stray prose/fences around the object
// (take the outermost {...}), but every one of the five fields must be a real finite JSON number
// in [0, MAX_GRAMS] -- a numeric string, a range, or a missing key fails the whole estimate.
function parseEstimate(text: string) {
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

  const values: Record<string, number> = {};
  for (const f of FIELDS) {
    const v = obj?.[f];
    if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > MAX_GRAMS) {
      return { estimate: null, note };
    }
    values[f] = round1(v);
  }
  return { estimate: values, note };
}

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
    const { estimate, note } = response.stop_reason === "max_tokens"
      ? { estimate: null, note: null }
      : parseEstimate(text);

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

In the actual file, write the elided request-validation blocks out in full, copied from scan-vin
lines 30–59. Don't import them from a shared module: scan-vin doesn't have one, and introducing
one now would mean touching scan-vin.

Deliberately not done:
- No `thinking` (scan-vin doesn't use it).
- No assistant prefill (support on this model is unverified, and the brace-extraction already
  covers fences/prose).
- No server-side cross-field rejection such as `sugar_g > carbs_g`. That's checked manually in
  Step 7. See Risks.

### Step 5. Deploy scan-plate

```bash
cd /home/mmcbride/micah/claude/workflow-app
supabase functions deploy scan-plate --project-ref utwyvtbzesswpoihmlic --use-api
supabase functions list --project-ref utwyvtbzesswpoihmlic   # scan-plate ACTIVE, verify_jwt true
```

- **Always name the function.** A bare `functions deploy` would also deploy `mcp-server`.
- **Don't add a `[functions.scan-plate]` block** to config.toml. Its absence leaves `verify_jwt`
  on, same as scan-vin and agent-loop.
- **No new secret.** `ANTHROPIC_API_KEY` is project-wide and already set for scan-vin/agent-loop.
- **`--use-api`** follows the prod plan's convention. Plain `supabase functions deploy scan-plate`
  (Docker bundling) should also work here, since Docker is installed.

### Step 6. Preflight check (CORS + gateway)

```bash
curl -i -X OPTIONS https://utwyvtbzesswpoihmlic.supabase.co/functions/v1/scan-plate
```

Expect 200 with `Access-Control-Allow-Origin: *`. A 401 here is fine and just means the gateway
wants a JWT on OPTIONS; scan-vin has the same behavior.

### Step 7. Real end-to-end test of the deployed function, using the captured photo (required)

**Getting a bearer token.** The app uses Google OAuth (implicit flow), so there's no
password/service account to script against. Use the real signed-in session's access token:

1. On a desktop browser, open `https://datasciguycode.github.io/workflow-engine/` and sign in. If
   you're already signed in, reload and open any workflow so `GetValidAccessTokenAsync` refreshes a
   near-expiry token.
2. In the DevTools console, run:
   ```js
   JSON.parse(localStorage.getItem("workflow-app.auth-session.utwyvtbzesswpoihmlic")).access_token
   ```
   Also check `.expires_at` against `Date.now()/1000`. Tokens last about 1 h.
3. Paste it into a shell variable without echoing it into history: `read -rs SB_JWT; export SB_JWT`.

Do **not** use the stored `refresh_token` to mint a token with curl. GoTrue rotates refresh tokens,
and reusing the browser's one outside the reuse window can revoke that session family, signing the
browser out.

**The call.** Build the body in the scratchpad, since there's no jq:

```bash
D=/tmp/claude-1000/-home-mmcbride-micah-claude-workflow-app/750872d2-abc1-4109-ae9e-41bd21b23f2f/scratchpad
python3 -I -c 'import base64,json,sys; print(json.dumps({"image_base64": base64.b64encode(open(sys.argv[1],"rb").read()).decode(), "media_type": "image/jpeg"}))' \
  /home/mmcbride/.claude/uploads/750872d2-abc1-4109-ae9e-41bd21b23f2f/50cc0461-image.jpg > "$D/plate-body.json"
curl -sS -w '\nHTTP %{http_code}\n' -X POST https://utwyvtbzesswpoihmlic.supabase.co/functions/v1/scan-plate \
  -H "Authorization: Bearer $SB_JWT" \
  -H "apikey: sb_publishable_Ec1_eTAJtWMb2AaC1ULE7w_8f0BvYsk" \
  -H "Content-Type: application/json" \
  --data-binary @"$D/plate-body.json"
```

The photo is about 1.7 MB as base64 and is sent unresized, which is under the API's per-image
limit. The UI path resizes to 1600 px, so if this call errors on size, resize via the UI path
instead.

**Pass criteria (not just "HTTP 200").** The plate shows 2 lacinato kale leaves, 2 carrots, half an
avocado, about 14 almonds, about 25 g of walnuts and about 2 tbsp of peanut butter. A rough hand
estimate is P≈18, C≈33, F≈52, fiber≈15, sugar≈10 g, about 650–700 kcal.

- All five fields are numbers (not null) and the response is HTTP 200.
- Each is roughly in band:

  | Field | Band (g) |
  |---|---|
  | protein | 8–35 |
  | carbs | 15–70 |
  | fat | 25–90 |
  | fiber | 6–30 |
  | sugar | 2–25 |

- **Fat is the largest of protein/carbs/fat.** Nuts, avocado and PB dominate, so this is the
  strongest "not garbage" signal.
- `fiber_g ≤ carbs_g` and `sugar_g ≤ carbs_g`.
- `4P + 4C + 9F` lands between 350 and 1300 kcal.
- `uncertainty_note` is a non-empty string that names at least some of the foods and mentions
  portion size/scale. The cutlery is a partial scale reference, so "some reference" is also
  acceptable.

Also run two negative checks:
1. Same call without the `Authorization` header: expect 401 from the gateway.
2. A non-food image, e.g. any photo of a car: expect 200 with all five `null` and a populated
   `uncertainty_note`.

Run the main call 2–3 times to see the variance between estimates. Record the outputs in the
commit message or PROGRESS.md, not in a new file.

If the numbers are garbage (e.g. fat lowest, or totals > 3000 kcal), iterate on `SYSTEM_PROMPT`
and redeploy **before** building the UI on top.

### Step 8. Client API (`web/Services/WorkflowApiClient.cs`)

**8a. `WorkflowSummary`.** Add the two columns:
```csharp
public record WorkflowSummary(string Id, string Name, string ItemLabel, string? ItemLabelPlural, bool GroupItemsByDate);
```
- In **both** `GetWorkflowsAsync` and `GetWorkflowAsync`, change
  `select=id,name,item_label` to `select=id,name,item_label,item_label_plural,group_items_by_date`.
- Construct the record with `r["item_label_plural"]?.GetValue<string>()` and
  `r["group_items_by_date"]?.GetValue<bool>() ?? false`. A JSON `null` comes back as a null
  `JsonNode`, so `?.` yields null.
- `Home.razor` only holds a `List<WorkflowSummary>` and never constructs one, so nothing else
  changes.

**8b. New `FoodScanResult` record.** Place it next to the other records:
```csharp
// scan-plate's response (2026-11-11): all five grams fields are either all numbers or all null
// (the function rejects a partial/invalid estimate wholesale); UncertaintyNote can be present
// either way -- on a failed scan it's the model's reason (e.g. no food visible).
public record FoodScanResult(double? ProteinG, double? CarbsG, double? FatG, double? FiberG, double? SugarG, string? UncertaintyNote)
{
    public bool HasEstimate => ProteinG is not null && CarbsG is not null && FatG is not null && FiberG is not null && SugarG is not null;
}
```

**8c. `CreateItemInStageAsync`.** Place it right after `MoveStageAsync`:
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

- **Overload resolution.** PostgREST resolves overloads by the named keys in the body.
  `{p_workflow_id, p_stage_id, p_data}` matches only the 3-arg function.
- **Response shape.** A non-`setof` composite return comes back as a JSON object. The `JsonArray`
  branch is defensive, in case that assumption is wrong.

**8d. `ScanFoodPhotoAsync`.** Place it right after `ScanVinAsync`, mirroring it:
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
`GetValue<double>()` on a JSON integer like `18` works with System.Text.Json's `JsonValue`.

### Step 9. `web/Pages/WorkflowDetail.razor`

All edits are listed in file order.

**9a. Header Chat button (line ~42).** Replace `@if (_newJobMode || _selectedItem is not null)` with
`@if (ChatAvailable)`. Append one sentence to the comment above it:
"...or hidden on the stage-chooser New screen, where there's nothing for chat to do (2026-11-11)."

**9b. Stage-view heading (line 56).** `Job #@JobNumber(_selectedItem)` →
`@ItemLabelSingular #@JobNumber(_selectedItem)`.

**9c. Scan-plate block.** Insert directly after the Scan VIN block (after line 90, before the
`scheduled_at` block):
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
        @if (_plateScanNote is { } note && note.ItemId == _selectedItem.Id)
        {
            <p style="opacity:0.75;">Estimate note: @note.Text</p>
        }
        @if (_plateScanError is not null)
        {
            <p style="opacity:0.75; color:var(--colorPaletteRedForeground1, #c00);">@_plateScanError</p>
        }
    </div>
}
```

**9d. Job-overview heading (line 118).** `Job #@JobNumber(_selectedItem)` →
`@ItemLabelSingular #@JobNumber(_selectedItem)`.

**9e. New-item screen (lines 141–179).** Restructure as below. The mechanic branch (initial stage
exists) has the same content in the same order: the "Other Appointments" block just moves inside
it.
```razor
else if (_newJobMode)
{
    <h1>New @ItemLabelSingular</h1>
    @if (_stages.FirstOrDefault(s => s.IsInitial) is { } initialStage)
    {
        ...existing "Starts in" paragraph + checklist stack, unchanged...

        ...existing Other Appointments comment + block, unchanged, moved inside this branch...
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

**9f. Jobs/Entries list header (lines 183–186).**
- Keep the `+ New @ItemLabelSingular` link as is. It already uses the label, so the mechanic sees
  "+ New Job" and Diet sees "+ New Entry".
- Wrap the Show/Hide closed `FluentLink` in `@if (!AllStagesTerminal) { ... }`.
- Search placeholder: `Placeholder="Search jobs..."` →
  `Placeholder="@($"Search {ItemLabelPlural.ToLowerInvariant()}...")"`.

**9g. Plain list (lines 220–233).** Turn the `else` into `else if (_workflow?.GroupItemsByDate ==
true) { grouped } else { existing flat list, untouched }`:
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
Search results stay a flat list in both modes. They're an explicit query, and the existing comment
already treats search as exempt from list-display rules.

**9h. Chat section condition (line 256).** `@if (_newJobMode || _selectedItem is not null)` →
`@if (ChatAvailable)`.

**9i. `@code` members.**
- **`ItemLabelPlural`** (line 396) becomes:
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
  // could only ever fail, so it's hidden until an item actually exists (2026-11-11).
  private bool ChatAvailable =>
      _selectedItem is not null || (_newJobMode && _stages?.Any(s => s.IsInitial) == true);
  ```
- **`AllStagesTerminal`** goes above `VisibleItems`. `VisibleItems` gets an extra first condition:
  ```csharp
  // Every stage terminal (e.g. Diet, 2026-11-11) means items never move and nothing is ever
  // "open" -- so there's nothing to hide as closed and no stage to "complete" into the next one.
  private bool AllStagesTerminal => _stages is { Count: > 0 } && _stages.All(s => s.IsTerminal);

  private IEnumerable<ItemSummary> VisibleItems() =>
      _showClosed || AllStagesTerminal
          ? _items!
          : _items!.Where(i => _stages!.FirstOrDefault(s => s.Id == i.StageId)?.IsTerminal != true);
  ```
- **`ItemTitle` fallback** (line 520): `ItemLabelPlural.TrimEnd('s')` → `ItemLabelSingular`. This
  is identical for job/ticket, and correct for entries.
- **`DoneNextStage`**: add `if (AllStagesTerminal) return null;` as its first line, and extend its
  comment with "...or every stage in the workflow is terminal (2026-11-11)".
- **`CreateItemInStage`** + state goes next to `StartNewJob`:
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
  `CancelNewJob` also clears `_createItemError`. That changes it from an expression body to a
  two-statement body.
- **`OnFoodPhotoSelected`** + state goes directly after `OnVinPhotoSelected`, mirroring it line for
  line:
  ```csharp
  private bool _scanningPlate;
  private string? _plateScanError;
  // Tagged with the item it was produced for, so moving to another entry doesn't show the
  // previous plate's caveat next to different numbers (2026-11-11).
  private (string ItemId, string Text)? _plateScanNote;

  // Same resize-then-send-once path as OnVinPhotoSelected; writes the five estimates through
  // the direct UpdateDataAsync wrapper into the entry that's open, never via chat (2026-11-11).
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
          if (scan.UncertaintyNote is { } note)
              _plateScanNote = (itemId, note);
          _items = await Api.GetItemsAsync(WorkflowId);
          _selectedItem = _items.FirstOrDefault(i => i.Id == itemId);
          if (_selectedItem is not null)
              await LoadFieldStageMap(_selectedItem.Id);
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
  - Capturing `itemId` up front, rather than reading `_selectedItem.Id` after the awaits, is a
    small deviation from the VIN handler. It guarantees the write goes to the entry that was open
    when the photo was taken, even if the user navigates during the scan.
  - `JsonObject` accepts `double?` via implicit `JsonNode` conversion. A null would write JSON
    null, but `HasEstimate` guarantees none are null.

### Step 10. Build and local smoke

```bash
cd /home/mmcbride/micah/claude/workflow-app
dotnet build web/WorkflowApp.Web.csproj
```

If a local `dotnet run`/`watch` against the dev backend is the usual loop, use it for Step 11
before pushing. Otherwise Step 11 runs on the deployed Pages site after Step 12.

### Step 11. UI verification

**Diet (on a phone, for the camera path):**
1. The Workflows list shows "Diet". Opening it shows the heading "Entries", the link "+ New Entry",
   and **no** Show/Hide closed toggle. With no entries, the list is empty with no error.
2. "+ New Entry" shows the heading "New Entry", 5 stage buttons in order (Nutrition goal,
   Breakfast, Lunch, Dinner, Snack), **no** Other Appointments, and **no** chat box or header Chat
   button.
3. Tap Breakfast. You should land on "Entry #1 — Breakfast" with 6 checklist rows, **no `*`
   anywhere**, a **Scan Plate** button, and **no Complete Stage** button next to Send.
4. Scan Plate on a real plate. Five values should appear as checked fields, and "Estimate note: ..."
   should show below the button.
5. In chat, type "bump protein to 30g". The agent should update `protein_g` via update_data and
   should **not** offer to move the entry to another stage.
6. Back to Entries. There should be a heading for today with "#1 Breakfast →" and a time.
   - Create a Snack and a second Snack. They should appear under the same day in creation order.
   - Create a Nutrition goal. Its view should show the 5 `*_goal_g` fields, **no Scan Plate**, and
     no `*`.
7. Search for "breakfast". It should return a flat result list (matches stage title), with no
   grouping.

**Mechanic regression (Joe's Auto Repair).** It must look exactly as it does today:
- "Jobs" / "+ New Job" / Show closed toggle present.
- The flat list still shows `#N Title` / `Stage: X`, and closed jobs are still hidden by default.
- "+ New Job" still shows the Intake checklist, Other Appointments, and the chat. Creating a job via
  chat still auto-drills into Intake.
- The headings still read "Job #N".
- Diagnosis still shows Scan VIN and **not** Scan Plate.
- A job at payment_receipt_submitted with payment_method filled still offers **Complete Stage**
  (→ closed).
- The `*` markers are unchanged.

### Step 12. Commit, push, PROGRESS.md

- **Commits.** One commit for migrations + function, one for the web app. Or a single commit, per
  the user's preference. Push only when the user asks. Pushing to `main` triggers
  `deploy-pages.yml` (path filter `web/**`).
- **PROGRESS.md.** Add a lean line covering:
  - the Diet workflow is live on dev;
  - the generic stage-chooser (no is_initial);
  - `item_label_plural` / `group_items_by_date`;
  - scan-plate;
  - the Step 7 test outputs, in one line.

## 4. Assumptions not verified

- **PostgREST returns a single JSON object** for a non-setof composite RPC return. The wrapper
  handles an array too, just in case.
- **`TimeZoneInfo.Local` in Blazor WASM is the browser's zone.** The existing notes timestamps
  already rely on this, but I haven't verified it independently.
- **The label-wrapped `FluentButton` file picker works on the target phone.** Scan Plate inherits
  exactly whatever Scan VIN does, so if one doesn't open the camera, neither does the other.
- **`claude-sonnet-5-5` reliably follows the JSON-only instruction.** The fallback extraction plus
  validation means a non-compliant reply turns into a "couldn't estimate" message, not bad data.
- **Gateway `verify_jwt` behavior on OPTIONS (Step 6)** matches scan-vin's, whatever that is.

## 5. Risks and edge cases

- **Inherited cost exposure.** scan-plate, like scan-vin, only relies on the gateway's JWT
  verification. Any valid project JWT can call it and spend Anthropic credits. That includes the
  legacy anon JWT, if legacy keys are still enabled. Parity with scan-vin was the brief, and
  tightening both (e.g. checking `/auth/v1/user` + account membership) is a separate follow-up.
- **Rescanning overwrites.** A second scan on the same entry replaces all five values; it does not
  add to them ("seconds" are lost). Corrections go through chat by design. A second helping can be
  its own snack entry.
- **No back-dating.** An entry's day is its `created_at`, so a meal logged after midnight lands on
  the next day. There's no UI to change `created_at`, and that's out of scope. It matters for the
  future reporting tool, which must also pick a timezone convention consistent with D4.
- **Job overview page for Diet items.** Tapping an entry in the list opens the generic overview
  (all 5 stage cards with checkboxes). Opening, say, the Lunch card on a Breakfast entry shows the
  same macro keys as "done", because the keys are shared across meal stages, and chat there would
  write onto the breakfast entry. This is functional but confusing.
  - **Not fixed here (outside the settled design).** The obvious minimal follow-up: when
    `AllStagesTerminal`, `SelectItem` opens the item's own stage view directly and the back link
    returns to the list. **Flagged for the architect to decide.**
- **List scale.** Diet adds about 4–6 items/day. `GetItemsAsync` loads every item, and
  `JobNumber()` re-sorts the full list per card (O(n² log n) per render). That's fine for weeks,
  sluggish after many months. This is pre-existing and shared with the mechanic list. Pagination
  or memoizing the number map is a follow-up.
- **Cross-field plausibility.** `sugar_g`/`fiber_g` greater than `carbs_g` isn't rejected
  server-side; Step 7 checks it manually. If it shows up in practice, add the check to
  `parseEstimate`.
- **agent-loop prompt text says "mechanic-shop".** Diet chat works because the stages JSON
  (including checklist keys) is in the prompt, and the terminal-stage rule suppresses move nudges.
  The wording is untouched per scope.
- **Rollback.**
  - Web: revert the web commit. The Pages deploy re-runs, and the new columns are simply ignored by
    the old client. `select=` names only columns it knows.
  - Function: `supabase functions delete scan-plate --project-ref utwyvtbzesswpoihmlic`.
  - Data: Diet rows can be left in place harmlessly. Removing them needs service-role SQL, because
    there are no DELETE policies, and items/events reference the stages.
  - The two `workflows` columns are additive and nullable/defaulted. Dropping them is safe once the
    old client is back.

## 6. Out of scope (deliberate)

- Any day-level/parent item or linking between meals.
- Totals, rollups, goal-vs-actual comparison, reporting app or SQL view.
- "Goal in effect on date X" resolution.
- A correction UI for scanned values. Chat/update_data already covers it.
- Persisting the uncertainty note.
- Changes to `agent-loop` (including teaching its `create_item` tool about stages).
- Back-dating entries, and the Diet-specific overview-page navigation noted in Risks.
- Porting any of this to prod.
