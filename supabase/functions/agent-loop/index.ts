// Phase 4a (SPEC.md §6/§7): text-first slice of the voice-agent UI. Takes a plain-text
// instruction instead of a voice transcript (voice/cloud-STT-TTS wiring is Phase 4b) and runs a
// Claude Messages API tool-use loop against the engine's existing RPCs.
//
// UNTESTED end to end as of this commit -- see GOAL.md/log for 2026-10-13. There's no Deno
// runtime or ANTHROPIC_API_KEY available in the environment this was written in, so this has
// been reviewed carefully against SPEC.md and the actual RPC signatures in
// supabase/migrations/*.sql, but never actually invoked. Treat it as a reviewed draft, not a
// proven one, until it's run for real with `supabase functions serve` + a real API key.
//
// Design: no custom two-phase tool-interception protocol -- Claude just calls tools directly as
// instructions come in, via a normal multi-turn Messages API conversation. The caller (client)
// holds the full message history client-side and sends it back each call -- this function is
// stateless, same as the reference queue is UI-local state, not server state (SPEC.md §6).
// Originally (2026-10-13, carried over from contractor-tracker's 2026-09-21 decision) this used a
// confirm-before-write pattern -- describe the action in plain text and wait for an explicit "yes"
// before calling any tool. Dropped 2026-10-21: the user's own message is already visible in the
// chat UI, so a separate restate-and-confirm round trip was pure friction, not a real safety
// check (nothing here is destructive enough to warrant it, and a wrong move is just another chat
// message away from being corrected).

import Anthropic from "npm:@anthropic-ai/sdk@0.32.1";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-5-5";

// job_number is the UI's stable, permanent per-workflow identifier (shown on screen as "Job #N"),
// distinct from `number`, which is this queue's own display-order numbering ("number one" = top
// of the Jobs list right now, per the 2026-10-16 redesign) -- kept separate on purpose. job_number
// lets the model resolve a user saying "job 2" / "job #2" to the right item_id even when that
// differs from both queue position and which job is currently open.
type QueueEntry = { number: number; job_number?: number; item_id: string; label?: string };

type RequestBody = {
  workflow_id: string;
  queue: QueueEntry[];
  messages: Anthropic.MessageParam[]; // full prior history; first call has one user message
  // The job/stage currently drilled into in the UI, if any -- lets the agent default an
  // ambiguous message ("appointment tomorrow at 3") to the job the user is actually looking at
  // instead of always asking "which job?" (2026-10-20: queue-only disambiguation asked even when
  // the user was clearly mid-conversation about one specific job on screen).
  selected_item_id?: string;
  selected_item_label?: string;
  selected_stage_title?: string;
  // Raw id of the stage drilled into, if any -- distinct from selected_stage_title (display-only).
  // add_note needs the real id to tag a note the same way the UI's own "Save as note" checkbox
  // does: that stage's id when one is open, or omitted for a job-level note made from the job
  // overview page (2026-11-08).
  selected_stage_id?: string;
  // Client-computed display name for the selected item (e.g. "Job #5" for the mechanic
  // workflow, "Breakfast 2026-11-12" for Nutrition Tracker's meal entries -- see
  // ItemDisplayName in WorkflowDetail.razor) -- this function stays workflow-agnostic by never
  // hardcoding "Job #" itself and just echoing back whatever the client decided this item
  // should be called (2026-11-12, after the agent asked the user "whose log should I put this
  // lunch under?" on Nutrition Tracker, a mechanic-shop-specific assumption baked into the old
  // selected_job_number/"Job #" wording below that doesn't apply to every workflow).
  selected_item_display_name?: string;
  // Count of the user's own messages sent in this exact job+stage so far (including this one).
  // Past a threshold, the system prompt nudges the agent to capture further detail via add_note
  // instead of letting it accumulate as raw chat text (2026-11-07) -- notes are plain stored
  // text, never replayed into later requests, so they don't grow token cost the way chat does.
  selected_stage_message_count?: number;
};

// Thin wrapper around PostgREST, forwarding the CALLER's own JWT (not the service role key) so
// RLS applies exactly as it would for a direct call -- the RPCs are SECURITY INVOKER (SPEC.md
// §1A), and this function is just another caller of them, same as the UI or any script.
async function restFetch(path: string, jwt: string, body?: unknown) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${jwt}`,
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : null;
  if (!res.ok) {
    throw new Error(`${path} failed (${res.status}): ${JSON.stringify(json)}`);
  }
  return json;
}

// Writes a row to agent_events (usage or error), best-effort -- a logging failure should never
// break the actual chat/tool-call response, so this swallows its own errors (2026-11-08).
async function logAgentEvent(
  jwt: string,
  workflowId: string,
  itemId: string | undefined,
  patch: Record<string, unknown>,
) {
  try {
    await restFetch("/agent_events", jwt, {
      workflow_id: workflowId,
      item_id: itemId ?? null,
      ...patch,
    });
  } catch (_e) {
    // best-effort telemetry; intentionally not surfaced
  }
}

async function fetchStages(workflowId: string, jwt: string) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/stages?workflow_id=eq.${workflowId}&select=id,title,sequence_order,is_initial,is_terminal,checklist&order=sequence_order.asc.nullslast`,
    { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${jwt}` } },
  );
  if (!res.ok) {
    throw new Error(`fetching stages failed (${res.status}): ${await res.text()}`);
  }
  return await res.json();
}

const TOOLS: Anthropic.Tool[] = [
  {
    name: "create_item",
    description:
      "Create a new item in the active workflow. It lands automatically in the workflow's is_initial stage. " +
      "If data.title is present, the UI displays it as the item's heading -- but title is OPTIONAL, not " +
      "something to chase: only include it when the workflow has a natural named entity to anchor on (e.g. a " +
      "customer, for the mechanic-shop workflow -- compose it yourself as \"{customer} - {short task}\", a few " +
      "words, not the full sentence; never copy the raw request/complaint text verbatim into title, put that in " +
      "its own field like data.description instead). For a workflow with no such entity (e.g. a recurring daily " +
      "log), omit title entirely -- the UI falls back to a sensible default (the stage and date) on its own. " +
      "Never ask the user for a name just to satisfy a title -- only ask for information actually missing from " +
      "the active stage's checklist, and otherwise create the item right away from whatever they already told you.",
    input_schema: {
      type: "object",
      properties: {
        data: {
          type: "object",
          description:
            "Initial free-form fields for the item -- e.g. for a job-like workflow: {title: \"Bob - cat removal\", " +
            "customer: \"Bob\", phone: \"999-999-9999\", description: \"Cat needs to be removed from the car\"}; " +
            "for a workflow with no natural title (e.g. a daily log), just the checklist-style fields with no " +
            "title key at all, e.g. {protein_g: 20, carbs_g: 15, fat_g: 30}.",
        },
      },
      required: ["data"],
    },
  },
  {
    name: "move_stage",
    description:
      "Move an existing item to a different stage in its workflow. Omit item_id to target the item currently open in the UI (see the note above the queue) -- only pass item_id explicitly when the user's message clearly names a different item (by queue number, a number/label shown on screen, or a distinguishing detail). May be rejected by the workflow's stage-order rules (e.g. a forward skip when enforce_stage_order is true) -- if so, explain the rejection to the user in plain text, don't retry silently.",
    input_schema: {
      type: "object",
      properties: {
        item_id: { type: "string", description: "uuid of the item to move; omit to use the item currently open in the UI" },
        to_stage_id: { type: "string", description: "uuid of the destination stage" },
      },
      required: ["to_stage_id"],
    },
  },
  {
    name: "update_data",
    description:
      "Apply a top-level merge patch to an item's data. Omit item_id to target the item currently open in the UI (see the note above the queue) -- only pass item_id explicitly when the user's message clearly names a different item (by queue number, a number/label shown on screen, or a distinguishing detail); this matters even if a different item was discussed earlier in the conversation -- a message with no item reference, while one item is open in the UI, always means that open item. Each key in the patch replaces that key's value wholesale; a top-level null deletes that key. Arrays are replaced wholesale, never appended -- to add to an array field, include the whole new array (read-modify-write).",
    input_schema: {
      type: "object",
      properties: {
        item_id: { type: "string", description: "uuid of the item to update; omit to use the item currently open in the UI" },
        patch: { type: "object" },
      },
      required: ["patch"],
    },
  },
  {
    name: "add_note",
    description: "Add a free-text note to an item's history, shown to the user in the UI's own Notes section. Does not change the item's data. Prefer this over just replying in chat for any detailed commentary, context, or explanation that doesn't map to a checklist field or a direct instruction -- notes are the durable record for that kind of detail; chat is for short back-and-forth. Omit item_id to target the item currently open in the UI (see the note above the queue) -- only pass item_id explicitly when the user's message clearly names a different item. The note is automatically tagged with whichever stage (if any) is currently drilled into in the UI -- an item-level note vs. a stage-specific one is decided entirely by where the user is looking, not by anything you choose here.",
    input_schema: {
      type: "object",
      properties: {
        item_id: { type: "string", description: "uuid of the item to note; omit to use the item currently open in the UI" },
        note: { type: "string" },
      },
      required: ["note"],
    },
  },
];

async function callTool(
  name: string,
  input: Record<string, unknown>,
  workflowId: string,
  jwt: string,
  selectedItemId: string | undefined,
  selectedStageId: string | undefined,
) {
  // For every tool that targets an existing item, the model may omit item_id to mean "the job
  // currently open in the UI" -- resolved HERE, server-side, from the request body's own
  // selected_item_id, not from anything the model inferred. This is the actual fix for a real
  // 2026-11-07 bug: with a full, unscoped conversation history, the model picked a *different*,
  // more recently-discussed job over the one actually open on screen, even though the system
  // prompt named it. Making the common case a deterministic server-side default (rather than a
  // model free-choice every time) removes that failure mode for any call where the model follows
  // the tool description's instruction to omit item_id by default.
  const itemId = (input.item_id as string | undefined) ?? selectedItemId;
  switch (name) {
    case "create_item":
      return await restFetch("/rpc/create_item", jwt, {
        p_workflow_id: workflowId,
        p_data: input.data ?? {},
      });
    case "move_stage":
      if (!itemId) throw new Error("no job is open in the UI and no item_id was given");
      return await restFetch("/rpc/move_stage", jwt, {
        p_item_id: itemId,
        p_to_stage_id: input.to_stage_id,
      });
    case "update_data":
      if (!itemId) throw new Error("no job is open in the UI and no item_id was given");
      return await restFetch("/rpc/update_data", jwt, {
        p_item_id: itemId,
        p_patch: input.patch,
      });
    case "add_note":
      if (!itemId) throw new Error("no job is open in the UI and no item_id was given");
      // Only tag the note with selectedStageId when the note is actually about the job that's
      // open in the UI (itemId fell through to selectedItemId, i.e. the model omitted item_id).
      // An explicit item_id naming some OTHER job has no known stage context here without an
      // extra lookup, so that note lands as job-level (null) rather than guessing a stage.
      return await restFetch("/rpc/add_note", jwt, {
        p_item_id: itemId,
        p_note: input.note,
        p_stage_id: input.item_id ? null : (selectedStageId ?? null),
      });
    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

function systemPrompt(
  stages: unknown,
  queue: QueueEntry[],
  selectedItemId?: string,
  selectedItemLabel?: string,
  selectedStageTitle?: string,
  selectedItemDisplayName?: string,
  selectedStageMessageCount?: number,
) {
  // Restated close to every turn (this whole prompt is rebuilt fresh each request) and reinforced
  // by move_stage/update_data/add_note's own tool descriptions, because a full unscoped message
  // history can otherwise make an earlier, more recently-discussed job feel more salient than
  // this one-line reminder -- a real failure mode observed 2026-11-07 (the agent wrote a new
  // appointment's date onto a different job that had just been created/discussed, instead of the
  // job actually open in the UI). The job number (if present) gives the model and the user a
  // shared, unambiguous way to refer to this exact job even when its label is generic.
  // Nudges the agent to capture further detail as a note instead of letting the conversation run
  // long -- notes are plain stored text the UI reads back directly, never replayed into later
  // requests, so they don't add token cost to every subsequent message in this stage the way
  // continued chat does. Deliberately a soft nudge in the model's own phrasing, not a disabled
  // input box -- a hard block risks stopping someone mid-task right when they need one more
  // exchange (2026-11-07).
  const noteNudge = (selectedStageMessageCount ?? 0) >= 5
    ? ` This stage's chat has already run ${selectedStageMessageCount} messages long. From here, prefer add_note over continuing to just talk about something -- if the user gives more free-form detail or commentary that isn't a direct instruction or a checklist-field value, save it with add_note and say so briefly, rather than only replying in chat.`
    : "";
  // selectedStageTitle is only set once a stage is actually drilled into -- the job overview page
  // (item selected, no stage) also has its own chat box now (2026-11-08), so this can't assume a
  // stage is always present just because an item is.
  const stageContext = selectedStageTitle
    ? `drilled into its "${selectedStageTitle}" stage's own view`
    : "on its own overview page (no particular stage drilled into)";
  const selectedContext = selectedItemId
    ? `\nTHE USER IS CURRENTLY LOOKING AT ONE SPECIFIC ITEM: ${selectedItemDisplayName ?? selectedItemLabel ?? selectedItemId} (id ${selectedItemId}), ${stageContext}. For move_stage, update_data, and add_note: omit item_id entirely to target this item -- that is the default and correct choice for any message that doesn't clearly name a different item, REGARDLESS of which other items were created or discussed earlier in this same conversation. Only pass an explicit item_id when the user's current message itself names a different item (by a number or label shown on screen, or a distinguishing detail) or asks to act on an item other than this one. Don't ask "which one?" just because other items also exist in the queue below -- the open one always wins unless the message says otherwise. A note added here is automatically tagged with the stage named above, if any -- it's an item-level note (no stage) when the user is on the overview page.${noteNudge}\n`
    : "";
  return `You are a workflow assistant for a generic items-moving-through-stages app (the active workflow could be a mechanic shop's job queue, a daily nutrition log, or anything else shaped the same way) -- never assume it's about jobs, customers, or repairs unless the stages/checklist below actually show that. You act on the user's spoken-or-typed instructions using the tools available to you.

Active workflow's stages (id, title, sequence_order, is_initial, is_terminal, checklist):
${JSON.stringify(stages)}
A stage's checklist, where present, lists the data.* field keys typically filled in at that stage
(e.g. a mechanic-shop intake stage: customer, phone, address; a nutrition-log breakfast stage:
protein_g, carbs_g, fat_g) -- a soft guide for what to ask about, not a hard requirement. Not
every item needs every checklist item filled in, and a missing one should never block creating
an item or moving it forward; just use it to know what's worth asking for if the user hasn't
already given it. When you do capture a value for one, write it via update_data (or in
create_item's initial data) using that exact key -- the UI shows each stage's checklist as
done/not-done by checking for that key in the item's data, so a note-only add_note call for it
won't show as done even though you recorded it somewhere.
${selectedContext}
Reference queue -- items recently mentioned or created in this conversation, numbered by order of mention (the user may say "number one", "the second one", etc. instead of a name). ${
    selectedItemId
      ? "Deliberately EMPTY right now because a specific item is open in the UI (above) -- act on that item alone; don't reference, compare to, or guess at other items by name even if they came up earlier in this conversation. This is expected, not an error."
      : "Populated because no specific item is open right now."
  }
${JSON.stringify(queue)}

Rules:
- Stage titles above are stored as snake_case ids (e.g. "in_progress", "payment_receipt_submitted"). When mentioning a stage in your reply, write it with spaces instead of underscores (e.g. "in progress", "payment receipt submitted") -- never show the raw underscored form to the user.
- The user may refer to an item by its queue number or a descriptive name/detail (e.g. "the Civic", or just "it"/"this one" when only one item is open).
- When a message reads like a task, request, or log entry (e.g. "Fix Bob's engine," "I had eggs and toast"), default to treating it as the item's own description/data -- something to track, not an instruction for you to carry out yourself. Only treat it as a literal instruction to you when it's clearly addressed to you as the assistant (e.g. "move this to diagnosis," "add a note that..."). If genuinely ambiguous, ask which one they mean before proposing a tool call -- but first check whether the item currently open in the UI (above, if any) already resolves the ambiguity.
- When creating an item from a request like that, don't use the raw request text as the title -- see create_item's description for how to split title vs. description (and when to skip title entirely).
- Act immediately -- the user's message is already visible on screen, so there's no need to restate what you're about to do and wait for a separate "yes" before calling a tool. Call the tool as soon as the instruction (or item-creation/move request) is clear; only ask first if it's genuinely ambiguous which item or stage is meant (see above).
- After a tool call succeeds, reply with a short acknowledgment only (e.g. "Saved."). Do not read back the data you just wrote.
- After a successful create_item, update_data, or add_note call (but not right after a move_stage -- you just said where it moved, don't immediately ask about moving it again), proactively add which stage the item is currently in and what the next stage is (by sequence_order), and ask if they want to move there now. Do this every time -- don't wait for the user to separately ask "what's next?". Skip it only if the item is already at a terminal stage (is_terminal).
- If a tool call fails (e.g. a rejected stage move), explain briefly in plain text what went wrong. Don't retry automatically.
- Keep replies short -- this is a voice interface; the user is hearing this read aloud, not reading it.`;
}

// Edge Functions get no CORS handling for free (unlike the PostgREST gateway the REST calls go
// through) -- the browser's preflight OPTIONS request otherwise falls through to the 405 below
// with no Access-Control-Allow-Origin header, which Safari/WebKit surfaces as an opaque
// "TypeError: Load failed" rather than a visible CORS error.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405, headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "missing bearer token" }), {
      status: 401,
      headers: corsHeaders,
    });
  }
  const jwt = authHeader.slice("Bearer ".length);

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid JSON body" }), {
      status: 400,
      headers: corsHeaders,
    });
  }
  if (!body.workflow_id || !Array.isArray(body.messages) || body.messages.length === 0) {
    return new Response(
      JSON.stringify({ error: "workflow_id and a non-empty messages array are required" }),
      { status: 400, headers: corsHeaders },
    );
  }
  const queue = body.queue ?? [];

  let stages;
  try {
    stages = await fetchStages(body.workflow_id, jwt);
  } catch (e) {
    return new Response(JSON.stringify({ error: `could not load workflow stages: ${e}` }), {
      status: 400,
      headers: corsHeaders,
    });
  }

  const anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY });
  const messages: Anthropic.MessageParam[] = [...body.messages];

  // Tool-use loop: Claude may call a tool, we execute it and feed back the result, and Claude
  // responds again -- repeat until it produces a turn with no tool_use blocks (a plain-text
  // reply, which per the system prompt is either the confirmation question or the final
  // acknowledgment/decline). Bounded to avoid an unbounded loop on unexpected model behavior.
  // Wrapped in try/catch: an uncaught throw here (a bad API key, a network error, a malformed
  // tool schema) would otherwise surface to the caller as an opaque 500 with no body -- caught
  // directly by a local smoke test on 2026-10-13 using a deliberately invalid API key.
  let finalText = "";
  try {
  for (let turn = 0; turn < 6; turn++) {
    // system is rebuilt every request from the current stages/queue, which changes across
    // chat turns as jobs are created/moved -- so thinking blocks from an earlier request are
    // routinely invalidated by the time the client sends its next message (the system prompt
    // "prefix" they were bound to no longer matches). block_binding.prefix_mismatch_behavior:
    // "drop_block" tells the API to drop stale thinking blocks and regenerate them instead of
    // hard-erroring (matches thinking-binding-controls-2026-08-01 beta semantics). This is a
    // documented stopgap, not a full fix -- the real fix would keep system/tools stable across
    // requests and push updates via mid-conversation role:"system" messages instead, which is a
    // bigger refactor than warranted for this local-dev UI pattern.
    const response = await anthropic.messages.create(
      {
        model: MODEL,
        max_tokens: 1024,
        system: systemPrompt(
          stages,
          queue,
          body.selected_item_id,
          body.selected_item_label,
          body.selected_stage_title,
          body.selected_item_display_name,
          body.selected_stage_message_count,
        ),
        tools: TOOLS,
        thinking: { type: "adaptive", block_binding: { prefix_mismatch_behavior: "drop_block" } },
        messages,
        // deno-lint-ignore no-explicit-any
      } as any,
      { headers: { "anthropic-beta": "thinking-binding-controls-2026-08-01" } },
    );

    messages.push({ role: "assistant", content: response.content });

    await logAgentEvent(jwt, body.workflow_id, body.selected_item_id, {
      event_type: "usage",
      input_tokens: response.usage.input_tokens,
      output_tokens: response.usage.output_tokens,
    });

    const toolUses = response.content.filter(
      (b): b is Anthropic.ToolUseBlock => b.type === "tool_use",
    );
    const textBlocks = response.content.filter(
      (b): b is Anthropic.TextBlock => b.type === "text",
    );
    finalText = textBlocks.map((b) => b.text).join("\n");

    if (toolUses.length === 0) {
      break; // plain-text turn -- confirmation question, decline, or final ack. Done.
    }

    const toolResults: Anthropic.ToolResultBlockParam[] = [];
    for (const toolUse of toolUses) {
      try {
        const result = await callTool(
          toolUse.name,
          toolUse.input as Record<string, unknown>,
          body.workflow_id,
          jwt,
          body.selected_item_id,
          body.selected_stage_id,
        );
        toolResults.push({
          type: "tool_result",
          tool_use_id: toolUse.id,
          content: JSON.stringify(result),
        });
      } catch (e) {
        const toolItemId = (toolUse.input as Record<string, unknown>).item_id as string | undefined;
        await logAgentEvent(jwt, body.workflow_id, toolItemId ?? body.selected_item_id, {
          event_type: "error",
          error_message: `${toolUse.name}: ${e}`,
        });
        toolResults.push({
          type: "tool_result",
          tool_use_id: toolUse.id,
          content: `error: ${e}`,
          is_error: true,
        });
      }
    }
    messages.push({ role: "user", content: toolResults });
  }
  } catch (e) {
    await logAgentEvent(jwt, body.workflow_id, body.selected_item_id, {
      event_type: "error",
      error_message: `agent loop failed: ${e}`,
    });
    return new Response(JSON.stringify({ error: `agent loop failed: ${e}` }), {
      status: 502,
      headers: corsHeaders,
    });
  }

  return new Response(JSON.stringify({ reply: finalText, messages }), {
    headers: { "Content-Type": "application/json", ...corsHeaders },
  });
});
