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
// Design (confirm-before-write, carried over from contractor-tracker's 2026-09-21 decision):
// rather than building a custom two-phase tool-interception protocol, the system prompt below
// just instructs Claude to always describe the action and wait for an explicit "yes" in the
// conversation BEFORE calling any tool. The actual RPC call only happens once Claude itself
// decides to invoke the tool, which (per the prompt) only happens after confirmation. This is
// deliberately simple: no separate "proposed action" state machine in this code, just a normal
// multi-turn Messages API conversation. The caller (client) holds the full message history
// client-side and sends it back each call -- this function is stateless, same as the
// reference queue is UI-local state, not server state (SPEC.md §6).

import Anthropic from "npm:@anthropic-ai/sdk@0.32.1";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-5-5";

type QueueEntry = { number: number; item_id: string; label?: string };

type RequestBody = {
  workflow_id: string;
  queue: QueueEntry[];
  messages: Anthropic.MessageParam[]; // full prior history; first call has one user message
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

async function fetchStages(workflowId: string, jwt: string) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/stages?workflow_id=eq.${workflowId}&select=id,title,sequence_order,is_initial,is_terminal&order=sequence_order.asc.nullslast`,
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
      "Create a new item in the active workflow. It lands automatically in the workflow's is_initial stage.",
    input_schema: {
      type: "object",
      properties: {
        data: {
          type: "object",
          description: "Initial free-form fields for the item, e.g. {customer, vehicle} or {title}.",
        },
      },
      required: ["data"],
    },
  },
  {
    name: "move_stage",
    description:
      "Move an existing item to a different stage in its workflow. May be rejected by the workflow's stage-order rules (e.g. a forward skip when enforce_stage_order is true) -- if so, explain the rejection to the user in plain text, don't retry silently.",
    input_schema: {
      type: "object",
      properties: {
        item_id: { type: "string", description: "uuid of the item to move" },
        to_stage_id: { type: "string", description: "uuid of the destination stage" },
      },
      required: ["item_id", "to_stage_id"],
    },
  },
  {
    name: "update_data",
    description:
      "Apply a top-level merge patch to an item's data. Each key in the patch replaces that key's value wholesale; a top-level null deletes that key. Arrays are replaced wholesale, never appended -- to add to an array field, include the whole new array (read-modify-write).",
    input_schema: {
      type: "object",
      properties: {
        item_id: { type: "string" },
        patch: { type: "object" },
      },
      required: ["item_id", "patch"],
    },
  },
  {
    name: "add_note",
    description: "Add a free-text note to an item's history. Does not change the item's data.",
    input_schema: {
      type: "object",
      properties: {
        item_id: { type: "string" },
        note: { type: "string" },
      },
      required: ["item_id", "note"],
    },
  },
];

async function callTool(
  name: string,
  input: Record<string, unknown>,
  workflowId: string,
  jwt: string,
) {
  switch (name) {
    case "create_item":
      return await restFetch("/rpc/create_item", jwt, {
        p_workflow_id: workflowId,
        p_data: input.data ?? {},
      });
    case "move_stage":
      return await restFetch("/rpc/move_stage", jwt, {
        p_item_id: input.item_id,
        p_to_stage_id: input.to_stage_id,
      });
    case "update_data":
      return await restFetch("/rpc/update_data", jwt, {
        p_item_id: input.item_id,
        p_patch: input.patch,
      });
    case "add_note":
      return await restFetch("/rpc/add_note", jwt, {
        p_item_id: input.item_id,
        p_note: input.note,
      });
    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

function systemPrompt(stages: unknown, queue: QueueEntry[]) {
  return `You are a workflow assistant for a mechanic-shop / task-tracking app. You act on the user's spoken-or-typed instructions using the tools available to you.

Active workflow's stages (id, title, sequence_order, is_initial, is_terminal):
${JSON.stringify(stages)}

Reference queue -- items recently mentioned or created in this conversation, numbered by order of mention (the user may say "number one", "the second one", etc. instead of a name):
${JSON.stringify(queue)}

Rules:
- The user may refer to an item by its queue number, or by a descriptive name/detail (e.g. "the Civic").
- CRITICAL: before calling any tool, state in plain text exactly what you are about to do (plain language, not raw tool syntax) and wait for the user's explicit go-ahead. Only call a tool after the user's most recent message clearly confirms (e.g. "yes", "do it", "go ahead"). If they decline or say no, acknowledge in plain text and do not call any tool.
- After a tool call succeeds, reply with a short acknowledgment only (e.g. "Saved."). Do not read back the data you just wrote.
- If a tool call fails (e.g. a rejected stage move), explain briefly in plain text what went wrong. Don't retry automatically.
- Keep replies short -- this is a voice interface; the user is hearing this read aloud, not reading it.`;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "missing bearer token" }), { status: 401 });
  }
  const jwt = authHeader.slice("Bearer ".length);

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid JSON body" }), { status: 400 });
  }
  if (!body.workflow_id || !Array.isArray(body.messages) || body.messages.length === 0) {
    return new Response(
      JSON.stringify({ error: "workflow_id and a non-empty messages array are required" }),
      { status: 400 },
    );
  }
  const queue = body.queue ?? [];

  let stages;
  try {
    stages = await fetchStages(body.workflow_id, jwt);
  } catch (e) {
    return new Response(JSON.stringify({ error: `could not load workflow stages: ${e}` }), {
      status: 400,
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
    const response = await anthropic.messages.create({
      model: MODEL,
      max_tokens: 1024,
      system: systemPrompt(stages, queue),
      tools: TOOLS,
      messages,
    });

    messages.push({ role: "assistant", content: response.content });

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
        );
        toolResults.push({
          type: "tool_result",
          tool_use_id: toolUse.id,
          content: JSON.stringify(result),
        });
      } catch (e) {
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
    return new Response(JSON.stringify({ error: `agent loop failed: ${e}` }), { status: 502 });
  }

  return new Response(JSON.stringify({ reply: finalText, messages }), {
    headers: { "Content-Type": "application/json" },
  });
});
