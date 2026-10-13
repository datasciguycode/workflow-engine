// TESTING AID ONLY -- not the Phase 4a production path. This exposes the engine's four RPCs
// (create_item/move_stage/update_data/add_note, same ones supabase/functions/agent-loop/index.ts
// wraps) as an MCP connector so the agent-design/confirm-before-write/reference-resolution
// behavior can be sanity-checked by chatting with Claude.ai directly (using the user's own
// subscription, no ANTHROPIC_API_KEY needed) instead of waiting on agent-loop's blockers (no
// ANTHROPIC_API_KEY, no local Deno runtime -- see GOAL.md/log for 2026-10-13).
//
// This does NOT validate agent-loop's actual code. agent-loop runs its own hand-rolled Claude
// Messages API tool-use loop; this is a different integration mechanism (MCP, consumed by the
// Claude.ai app's own connector client). Testing here proves out the RPCs, the tool
// descriptions/prompting, and whether confirm-before-write actually holds in practice -- useful
// signal, but agent-loop itself still needs a real API key + Deno to be considered proven.
//
// UNTESTED end to end, same as agent-loop: no Deno runtime available in the environment this was
// written in, so this has been reviewed against SPEC.md and the actual RPC signatures in
// supabase/migrations/*.sql, but never actually served or connected to Claude.ai. Treat it as a
// reviewed draft.
//
// Two layers of auth, deliberately different from each other:
//   1. Who can call this endpoint at all -- a shared secret (CONNECTOR_SECRET), checked the same
//      way contractor-tracker's old pilot/supabase/functions/mcp-server/index.ts did (timing-safe
//      compare against a bearer token or x-api-key header). Required because Claude.ai's
//      connector can't present a Supabase-issued JWT (verify_jwt is off for this function in
//      config.toml, same reason/comment as that old pilot).
//   2. What the RPCs see once inside -- NOT the service-role key (that pilot's choice, which
//      bypasses RLS entirely). Per SPEC.md §1A the RPCs are SECURITY INVOKER, so this function
//      mints a real JWT for one fixed seeded test user (default: Dana the dispatcher, same id
//      scripts/*.py use) and forwards that on every RPC call, exactly like agent-loop forwards
//      the real caller's JWT. RLS applies as it would for that user acting directly. This is a
//      testing-only shortcut (one fixed user, re-signed locally) -- never do this in the real
//      app, where each real user signs in and the app forwards THEIR session JWT.
//
// Setup (see GOAL.md/log 2026-10-13 for the full walkthrough):
//   1. `supabase secrets set CONNECTOR_SECRET=<your own random string>`
//   2. `supabase secrets set SUPABASE_JWT_SECRET=<the JWT secret from 'supabase status'>`
//      (local dev default is "super-secret-jwt-token-with-at-least-32-characters-long";
//      SUPABASE_URL and SUPABASE_ANON_KEY are already provided automatically by the platform)
//   3. Public reachability -- Claude.ai's connector needs a real HTTPS URL; local
//      `functions serve` only listens on localhost. CHECKED (2026-10-13): contractor-tracker's
//      working connector is NOT a tunnel -- it's deployed to a real, currently
//      ACTIVE_HEALTHY cloud Supabase project ("contractor-tracker-pilot", created 2026-09-19,
//      `supabase projects list` confirms it's live right now) via `supabase functions deploy
//      --use-api` (that pilot's own deploy.sh; plain CLI deploy stalled on Docker bundling, and
//      direct deploy was blocked by this session's permission check at the time -- the USER ran
//      the script, not Claude). workflow-app has NO cloud project yet (`supabase link`/`projects
//      list` confirm only local Docker dev exists). Creating one is the real unblock, but it's a
//      bigger step than this testing aid was scoped for -- new billable cloud infrastructure
//      under the user's real account -- so it isn't done here; see GOAL.md/log 2026-10-13 for
//      the decision this leaves open.
//   4. Once a cloud project exists and this function is deployed to it the same way: in
//      Claude.ai, Settings -> Connectors -> Add custom connector, URL
//      `https://<project-ref>.supabase.co/functions/v1/mcp-server/mcp`, auth header `x-api-key`
//      set to the same value as CONNECTOR_SECRET above.

import { McpServer, StreamableHttpTransport } from "npm:mcp-lite@0.8.2";
import { z } from "npm:zod@^4.1.12";
import { Hono } from "npm:hono@^4.6.14";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const JWT_SECRET = Deno.env.get("SUPABASE_JWT_SECRET")!;
const CONNECTOR_SECRET = Deno.env.get("CONNECTOR_SECRET");

// Default test identity: Dana (dispatcher), acct_1 -- same id scripts/phase0_isolation_test.py
// and scripts/phase4a_agent_loop_test.py already use. Override to test as a different member.
const TEST_USER_ID = Deno.env.get("TEST_USER_ID") ?? "8f3a0d26-5d86-4b18-8068-dae74693d42f";
const TEST_USER_EMAIL = Deno.env.get("TEST_USER_EMAIL") ?? "dana@example.com";

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Mints a Supabase-shaped access token for TEST_USER_ID, signed with the project's own JWT
// secret -- same approach as scripts/phase4a_agent_loop_test.py's mint_jwt, just in Deno/Web
// Crypto instead of Python's hmac module. Re-signed fresh on every MCP tool call rather than
// cached, since this is a low-volume testing aid, not a performance-sensitive path.
async function mintTestJwt(): Promise<string> {
  const header = { alg: "HS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    aud: "authenticated",
    role: "authenticated",
    sub: TEST_USER_ID,
    email: TEST_USER_EMAIL,
    iss: "supabase-demo",
    iat: now,
    exp: now + 3600,
  };
  const enc = new TextEncoder();
  const signingInput =
    `${b64url(enc.encode(JSON.stringify(header)))}.${b64url(enc.encode(JSON.stringify(payload)))}`;
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(JWT_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(signingInput));
  return `${signingInput}.${b64url(new Uint8Array(sig))}`;
}

// Same restFetch pattern as agent-loop/index.ts: forwards a real user JWT so the SECURITY
// INVOKER RPCs see real RLS, not a service-role bypass. GET here in addition to POST, since this
// server also needs read tools (list_workflows/list_items/list_stages) agent-loop doesn't have --
// agent-loop's caller already knows the workflow_id and queue up front; an MCP chat session has
// to discover them.
async function rest(method: "GET" | "POST", path: string, jwt: string, body?: unknown) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${jwt}`,
      ...(method === "POST" ? { Prefer: "return=representation" } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error(`${method} ${path} failed (${res.status}): ${JSON.stringify(json)}`);
  return json;
}

const reply = (body: unknown, isError = false) => ({
  content: [{ type: "text" as const, text: JSON.stringify(body, null, 2) }],
  ...(isError ? { isError: true } : {}),
});
const fail = (message: string) => reply({ ok: false, message }, true);

const mcp = new McpServer({
  name: "workflow-app-testing",
  version: "0.1.0",
  schemaAdapter: (schema) => z.toJSONSchema(schema as z.ZodType),
});

mcp.tool("list_workflows", {
  description:
    "List the workflows visible to the current test user's account (e.g. the mechanic shop, " +
    "the SDLC/feature pipeline). Call this first to get a workflow_id to use with the other tools.",
  inputSchema: z.object({}),
  handler: async () => {
    const jwt = await mintTestJwt();
    try {
      const rows = await rest("GET", "/workflows?select=id,title,enforce_stage_order", jwt);
      return reply({ ok: true, workflows: rows });
    } catch (e) {
      return fail(`Could not list workflows: ${e}`);
    }
  },
});

mcp.tool("list_stages", {
  description: "List a workflow's stages (id, title, sequence_order, is_initial, is_terminal).",
  inputSchema: z.object({ workflow_id: z.string().describe("uuid from list_workflows") }),
  handler: async (args: { workflow_id: string }) => {
    const jwt = await mintTestJwt();
    try {
      const rows = await rest(
        "GET",
        `/stages?workflow_id=eq.${args.workflow_id}&select=id,title,sequence_order,is_initial,is_terminal&order=sequence_order.asc.nullslast`,
        jwt,
      );
      return reply({ ok: true, stages: rows });
    } catch (e) {
      return fail(`Could not list stages: ${e}`);
    }
  },
});

mcp.tool("list_items", {
  description:
    "List items in a workflow (id, data, current stage_id) so you can resolve which item the " +
    "user means from a description (e.g. 'the Civic') before acting on it.",
  inputSchema: z.object({ workflow_id: z.string().describe("uuid from list_workflows") }),
  handler: async (args: { workflow_id: string }) => {
    const jwt = await mintTestJwt();
    try {
      const rows = await rest(
        "GET",
        `/items?workflow_id=eq.${args.workflow_id}&select=id,data,stage_id&order=created_at.desc`,
        jwt,
      );
      return reply({ ok: true, items: rows });
    } catch (e) {
      return fail(`Could not list items: ${e}`);
    }
  },
});

mcp.tool("create_item", {
  description:
    "Create a new item in a workflow; it lands in that workflow's is_initial stage " +
    "automatically. Per SPEC.md §6, describe exactly what you're about to create and wait for " +
    "the user's explicit go-ahead before calling this.",
  inputSchema: z.object({
    workflow_id: z.string(),
    data: z.record(z.string(), z.unknown()).describe("e.g. {customer, vehicle} or {title}"),
  }),
  handler: async (args: { workflow_id: string; data: Record<string, unknown> }) => {
    const jwt = await mintTestJwt();
    try {
      const row = await rest("POST", "/rpc/create_item", jwt, {
        p_workflow_id: args.workflow_id,
        p_data: args.data,
      });
      return reply({ ok: true, item: row });
    } catch (e) {
      return fail(`Could not create the item: ${e}`);
    }
  },
});

mcp.tool("move_stage", {
  description:
    "Move an item to a different stage. May be rejected by the workflow's stage-order rules " +
    "(e.g. a forward skip when enforce_stage_order is true) -- if rejected, explain it plainly, " +
    "don't retry silently. Confirm with the user before calling this, same as create_item.",
  inputSchema: z.object({ item_id: z.string(), to_stage_id: z.string() }),
  handler: async (args: { item_id: string; to_stage_id: string }) => {
    const jwt = await mintTestJwt();
    try {
      const row = await rest("POST", "/rpc/move_stage", jwt, {
        p_item_id: args.item_id,
        p_to_stage_id: args.to_stage_id,
      });
      return reply({ ok: true, item: row });
    } catch (e) {
      return fail(`Could not move the item: ${e}`);
    }
  },
});

mcp.tool("update_data", {
  description:
    "Apply a top-level merge patch to an item's data. Each key replaces that key's value " +
    "wholesale; a top-level null deletes that key. Arrays are replaced wholesale, never " +
    "appended. Confirm with the user before calling this.",
  inputSchema: z.object({ item_id: z.string(), patch: z.record(z.string(), z.unknown()) }),
  handler: async (args: { item_id: string; patch: Record<string, unknown> }) => {
    const jwt = await mintTestJwt();
    try {
      const row = await rest("POST", "/rpc/update_data", jwt, {
        p_item_id: args.item_id,
        p_patch: args.patch,
      });
      return reply({ ok: true, item: row });
    } catch (e) {
      return fail(`Could not update the item: ${e}`);
    }
  },
});

mcp.tool("add_note", {
  description: "Add a free-text note to an item's history. Does not change the item's data.",
  inputSchema: z.object({ item_id: z.string(), note: z.string().min(1) }),
  handler: async (args: { item_id: string; note: string }) => {
    const jwt = await mintTestJwt();
    try {
      const row = await rest("POST", "/rpc/add_note", jwt, {
        p_item_id: args.item_id,
        p_note: args.note,
      });
      return reply({ ok: true, event: row });
    } catch (e) {
      return fail(`Could not add the note: ${e}`);
    }
  },
});

// Shared-secret gate, same timing-safe-compare pattern as contractor-tracker's old pilot.
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const transport = new StreamableHttpTransport();
const httpHandler = transport.bind(mcp);

const app = new Hono();
const mcpApp = new Hono();

mcpApp.get("/", (c) =>
  c.json({ message: "workflow-app testing MCP connector", endpoints: { mcp: "/mcp", health: "/health" } }));

mcpApp.use("/mcp", async (c, next) => {
  if (!CONNECTOR_SECRET) return c.json({ error: "server not configured" }, 500);
  const bearer = c.req.header("authorization")?.replace(/^Bearer\s+/i, "");
  const given = c.req.header("x-api-key") ?? bearer ?? "";
  if (!timingSafeEqual(given, CONNECTOR_SECRET)) return c.json({ error: "unauthorized" }, 401);
  await next();
});

mcpApp.all("/mcp", async (c) => await httpHandler(c.req.raw));
mcpApp.get("/health", (c) => c.json({ status: "ok" }));

app.route("/mcp-server", mcpApp);

Deno.serve(app.fetch);
