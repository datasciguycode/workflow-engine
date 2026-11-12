// Single-purpose food-macro estimation from a photo (2026-11-12), same shape as scan-vin:
// deliberately NOT folded into agent-loop's tool-use chat loop -- one-shot read, no tool calls,
// no conversation history, the photo is never stored anywhere and never added to any chat log.
// The client writes the result straight into whichever meal stage is currently open via the
// existing direct update_data RPC wrapper, same as scan-vin does for the VIN field.
//
// Food-macro estimation from a photo is a much fuzzier task than VIN OCR (a VIN is exact
// characters to read off a plate; a plate of food is a visual guess at portion size and hidden
// ingredients), so unlike scan-vin's single regex check, this validates the model's answer
// against several bounds and cross-field relationships before trusting it, and asks the model to
// report its own uncertainty rather than present a guess as a precise measurement.

import Anthropic from "npm:@anthropic-ai/sdk@0.32.1";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-sonnet-5-5";

type RequestBody = {
  image_base64: string;
  media_type: string;
};

type FoodEstimate = {
  protein_g: number;
  carbs_g: number;
  fat_g: number;
  fiber_g: number;
  sugar_g: number;
  uncertainty_note: string;
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Generous per-field ceilings -- wide enough to never reject a real single-plate meal, tight
// enough to catch the model returning something nonsensical (e.g. misplacing a decimal point).
const MAX_PROTEIN_G = 250;
const MAX_CARBS_G = 400;
const MAX_FAT_G = 250;
const MAX_FIBER_G = 80;
const MAX_SUGAR_G = 250;
// Sugar and fiber are both sub-components of total carbs (see the 2026-11-11 conversation on
// starch) -- their sum can't legitimately exceed total carbs. +1 is rounding slack, not a real
// allowance.
const CARB_COMPONENT_SLACK_G = 1;
// Implied calories via the standard Atwater factors (protein/carbs = 4 kcal/g, fat = 9 kcal/g).
// 3000 sits above a whole large pizza, which is the point -- this only needs to catch answers
// that are wildly implausible for a single plate, not flag every big meal.
const MIN_IMPLIED_KCAL = 10;
const MAX_IMPLIED_KCAL = 3000;

function parseEstimate(raw: string): FoodEstimate | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const p = parsed as Record<string, unknown>;

  const protein_g = p.protein_g;
  const carbs_g = p.carbs_g;
  const fat_g = p.fat_g;
  const fiber_g = p.fiber_g;
  const sugar_g = p.sugar_g;
  const uncertainty_note = p.uncertainty_note;

  if (
    typeof protein_g !== "number" || !Number.isFinite(protein_g) ||
    typeof carbs_g !== "number" || !Number.isFinite(carbs_g) ||
    typeof fat_g !== "number" || !Number.isFinite(fat_g) ||
    typeof fiber_g !== "number" || !Number.isFinite(fiber_g) ||
    typeof sugar_g !== "number" || !Number.isFinite(sugar_g) ||
    typeof uncertainty_note !== "string"
  ) {
    return null;
  }
  if (protein_g < 0 || carbs_g < 0 || fat_g < 0 || fiber_g < 0 || sugar_g < 0) return null;
  if (
    protein_g > MAX_PROTEIN_G || carbs_g > MAX_CARBS_G || fat_g > MAX_FAT_G ||
    fiber_g > MAX_FIBER_G || sugar_g > MAX_SUGAR_G
  ) {
    return null;
  }
  if (fiber_g + sugar_g > carbs_g + CARB_COMPONENT_SLACK_G) return null;

  const impliedKcal = 4 * protein_g + 4 * carbs_g + 9 * fat_g;
  if (impliedKcal < MIN_IMPLIED_KCAL || impliedKcal > MAX_IMPLIED_KCAL) return null;

  return { protein_g, carbs_g, fat_g, fiber_g, sugar_g, uncertainty_note };
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
      // 512 was too tight -- a real end-to-end test on 2026-11-12 truncated the JSON mid-string
      // before the closing brace (uncertainty_note cut off), making an otherwise-good estimate
      // fail parseEstimate's JSON.parse. 1024 gives real headroom for the free-text note.
      max_tokens: 1024,
      system:
        "You are given a photo of a plate or container of food. Estimate its nutritional " +
        "content and respond with ONLY a single JSON object, no other text, no markdown fences, " +
        "in exactly this shape: " +
        '{"protein_g": <number>, "carbs_g": <number>, "fat_g": <number>, "fiber_g": <number>, ' +
        '"sugar_g": <number>, "uncertainty_note": "<short string>"}. ' +
        "All five nutrient values are grams, for the entire visible portion. fiber_g and sugar_g " +
        "are both sub-components of carbs_g (same as a nutrition label breaks out Total " +
        "Carbohydrate into Dietary Fiber and Total Sugars), so fiber_g + sugar_g must never " +
        "exceed carbs_g. In uncertainty_note, briefly flag whatever makes this estimate less " +
        "reliable -- e.g. no size/scale reference visible so portion size is a guess, a sauce or " +
        "dressing that likely contains unlisted added sugar or oil, or a composite/mixed dish " +
        "that's harder to decompose than separated whole foods. If you can't identify any food " +
        'in the photo, respond with {"protein_g": 0, "carbs_g": 0, "fat_g": 0, "fiber_g": 0, ' +
        '"sugar_g": 0, "uncertainty_note": "no food identified in photo"}.',
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              // deno-lint-ignore no-explicit-any
              source: { type: "base64", media_type: body.media_type as any, data: body.image_base64 },
            },
            { type: "text", text: "Estimate the nutritional content of this food." },
          ],
        },
      ],
    });

    const text = response.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("")
      .trim();

    const estimate = parseEstimate(text);

    return new Response(JSON.stringify(estimate ?? { error: "could not produce a reliable estimate from this photo" }), {
      status: estimate ? 200 : 422,
      headers: { "Content-Type": "application/json", ...corsHeaders },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: `scan-plate failed: ${e}` }), {
      status: 502,
      headers: corsHeaders,
    });
  }
});
