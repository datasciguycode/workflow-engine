// Single-purpose odometer reading from a dashboard photo (2026-11-20). Same shape and reasoning
// as scan-vin/scan-plate: one-shot, no chat history, photo never stored. Exact-digit OCR like
// scan-vin, but a cluster shows several numbers (trip A/B, range, speed) and analog odometers
// have a tenths drum, so the model must say which number it read and the caller validates.

import Anthropic from "npm:@anthropic-ai/sdk@0.32.1";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-5-5";

type RequestBody = {
  image_base64: string;
  media_type: string;
};

type OdometerReading = { reading: number; unit: "mi" | "km"; note: string };
const MAX_READING = 1_999_999;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function parseReading(raw: string): OdometerReading | null {
  let p: unknown;
  try {
    p = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof p !== "object" || p === null) return null;
  const { reading, unit, note } = p as Record<string, unknown>;
  if (reading === null) return null;
  if (typeof reading !== "number" || !Number.isFinite(reading)) return null;
  if (reading < 0 || reading > MAX_READING) return null;
  if (Math.round(reading * 10) !== reading * 10) return null; // at most one decimal
  if (unit !== "mi" && unit !== "km") return null;
  return { reading, unit, note: typeof note === "string" ? note : "" };
}

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
      max_tokens: 256,
      system:
        "You are given a photo of a vehicle's instrument cluster. Find the TOTAL ODOMETER " +
        "reading (often labelled ODO) -- NOT a trip meter (TRIP, TRIP A/B, A/B), NOT range or " +
        "distance-to-empty, NOT speed, temperature or fuel economy. On a mechanical odometer, a " +
        "final drum in a different colour (or separated) shows tenths: report it as a decimal " +
        "(48213.4), never append it as a whole digit. Respond with ONLY a JSON object, no " +
        "markdown: " +
        '{"reading": <number or null>, "unit": "mi" | "km" | null, "note": "<short>"}. ' +
        "Use null for reading if no odometer is clearly legible, or if you cannot tell which " +
        "number is the total odometer. In note, say which label you read it next to, and flag " +
        "any digit you were unsure of.",
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              // deno-lint-ignore no-explicit-any
              source: { type: "base64", media_type: body.media_type as any, data: body.image_base64 },
            },
            { type: "text", text: "Read the total odometer reading from this photo." },
          ],
        },
      ],
    });

    const text = response.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("")
      .trim();

    const reading = parseReading(text);

    return new Response(JSON.stringify(reading ?? { error: "could not read an odometer reliably from this photo" }), {
      status: reading ? 200 : 422,
      headers: { "Content-Type": "application/json", ...corsHeaders },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: `scan-odometer failed: ${e}` }), {
      status: 502,
      headers: corsHeaders,
    });
  }
});
