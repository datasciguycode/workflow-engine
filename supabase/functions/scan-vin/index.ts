// Single-purpose VIN extraction from a photo (2026-11-11). Deliberately NOT folded into
// agent-loop's tool-use chat loop: the photo never needs to enter conversation history (it's
// read once and discarded, never stored), there's no tool-calling needed since this is a single
// one-shot read, and keeping it separate means a bad/blurry photo never costs a slot in the
// bounded chat turn loop or pollutes the stage's chat log. The client writes the extracted VIN
// itself via a direct update_data RPC call (same pattern WorkflowApiClient.MoveStageAsync already
// uses for a UI action that doesn't need the model in the loop at all).

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

// Standard VIN alphabet excludes I, O, Q (too easily confused with 1/0) -- used to sanity-check
// the model's answer rather than trusting it blindly.
const VIN_PATTERN = /^[A-HJ-NPR-Z0-9]{17}$/;

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

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid JSON body" }), {
      status: 400,
      headers: corsHeaders,
    });
  }
  if (!body.image_base64 || !body.media_type) {
    return new Response(JSON.stringify({ error: "image_base64 and media_type are required" }), {
      status: 400,
      headers: corsHeaders,
    });
  }

  try {
    const anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY });
    const response = await anthropic.messages.create({
      model: MODEL,
      max_tokens: 64,
      system:
        "You are given a photo of a vehicle's VIN plate (dash corner, visible through the " +
        "windshield) or door-jamb sticker. Respond with ONLY the 17-character VIN itself -- no " +
        "punctuation, no spaces, no explanation. If no VIN is clearly legible in the photo, " +
        "respond with exactly: NOT_FOUND",
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              // deno-lint-ignore no-explicit-any
              source: { type: "base64", media_type: body.media_type as any, data: body.image_base64 },
            },
            { type: "text", text: "Extract the VIN from this photo." },
          ],
        },
      ],
    });

    const text = response.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("")
      .trim()
      .toUpperCase()
      .replace(/[^A-Z0-9]/g, "");

    const vin = VIN_PATTERN.test(text) ? text : null;

    return new Response(JSON.stringify({ vin }), {
      headers: { "Content-Type": "application/json", ...corsHeaders },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: `scan-vin failed: ${e}` }), {
      status: 502,
      headers: corsHeaders,
    });
  }
});
