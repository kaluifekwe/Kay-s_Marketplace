import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logAdminAction } from "../_shared/audit.ts";

// Writes one content_items draft: the blog article plus the five per-platform
// social variants (section 6/16 of the plan), from the topic/keyword/research
// already sitting in the row. Admin-gated, service role, matches every other
// admin-* function's shape (getUserIdFromToken + role check) so it satisfies
// the same CI guard.
//
// Claude Sonnet 5 is the primary writer; Gemini's free tier is the fallback
// ONLY if the Claude call itself fails (network/rate-limit/error) — not used
// for quality reasons, purely availability. Neither call happens unless an
// admin explicitly clicks Generate: this function is never scheduled or
// triggered automatically, so every model call is a deliberate, visible
// admin action (and a real, if tiny, cost).
//
// Plain fetch to each provider's REST API, no SDK — same convention as every
// other external integration in this codebase (flutterwave.ts, Paystack,
// Shipbubble, Terminal, Prembly all do raw fetch, not a vendor SDK).

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY") || "";
const geminiKey = Deno.env.get("GEMINI_API_KEY") || "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function getUserIdFromToken(authHeader: string | null): string | null {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return null;
  const token = authHeader.replace("Bearer ", "");
  if (!token || token === supabaseAnonKey) return null;
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const payload = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
    if (payload.exp && payload.exp < Math.floor(Date.now() / 1000)) return null;
    return payload.sub || null;
  } catch {
    return null;
  }
}

type Draft = {
  article_title: string;
  slug: string;
  meta_description: string;
  article_content: string;
  social_facebook: string;
  social_instagram: string;
  social_x: string;
  social_linkedin: string;
  social_whatsapp_status: string;
};

const DRAFT_KEYS: (keyof Draft)[] = [
  "article_title", "slug", "meta_description", "article_content",
  "social_facebook", "social_instagram", "social_x", "social_linkedin", "social_whatsapp_status",
];

// House style: fixed, reused on every call (cached on the Claude side; sent
// plain to Gemini, which has no equivalent caching for this call shape).
const SYSTEM_PROMPT = `You write for the Kay's Market blog: a Nigerian intrastate marketplace with
escrow protection, ID-verified vendors, and same-state delivery.

Content shape: Introduction (state the real problem immediately) -> a short
educational section -> the problem, in concrete Nigerian terms -> a practical,
actionable solution -> a natural mention of how Kay's Market addresses it,
ONLY when it genuinely fits. Do NOT force Kay's Market into every paragraph —
the article must be useful even to a reader who has never heard of it.

Voice: plain, specific, Nigerian context (real states, real amounts in Naira,
real scenarios — a WhatsApp vendor going silent, a rider demanding extra cash,
a courier with no tracking). Never invent a statistic, a quote, or a named
person/business.

Never write: "in today's digital age", "in today's fast-paced world", "in
conclusion", "moreover", "furthermore", filler introductions, keyword
stuffing, or an artificial wrap-up paragraph that just restates the title.

Output ONLY a single JSON object, no markdown code fence, no commentary
before or after it, with exactly these string keys:
- article_title: an SEO-natural headline, not clickbait
- slug: lowercase-hyphenated, matches the title, no stop words
- meta_description: under 155 characters, written to earn a click
- article_content: the full article in Markdown (use ## for headings), 500-900 words
- social_facebook: a Facebook post version of the same idea, 2-4 sentences
- social_instagram: an Instagram caption version, short, a hook first line
- social_x: an X/Twitter post, under 280 characters
- social_linkedin: a LinkedIn post version, slightly more formal, 3-5 sentences
- social_whatsapp_status: one short line, under 100 characters

Every value must be plain text/Markdown only — no nested JSON, no arrays.`;

function buildBrief(row: Record<string, unknown>): string {
  const lines = [
    `Topic: ${row.topic}`,
    row.keyword ? `Target keyword: ${row.keyword}` : null,
    `Audience: ${row.audience === "vendor" ? "Nigerian vendors/sellers" : "Nigerian buyers"}`,
    row.search_intent ? `Search intent: ${row.search_intent}` : null,
    row.category ? `Category: ${row.category}` : null,
    row.state ? `This article is specific to: ${row.state} state` : null,
    row.research_summary ? `Real pain point (write from this, don't invent beyond it): ${row.research_summary}` : null,
  ].filter(Boolean);
  return lines.join("\n");
}

/** Strip a ```json fence if the model added one despite instructions. */
function extractJson(text: string): string {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  return (fenced ? fenced[1] : text).trim();
}

function validateDraft(obj: unknown): Draft | null {
  if (!obj || typeof obj !== "object") return null;
  const rec = obj as Record<string, unknown>;
  for (const k of DRAFT_KEYS) {
    if (typeof rec[k] !== "string" || !(rec[k] as string).trim()) return null;
  }
  return rec as unknown as Draft;
}

async function generateWithClaude(brief: string): Promise<Draft> {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": anthropicKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-sonnet-5",
      max_tokens: 4000,
      output_config: { effort: "medium" },
      system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: brief }],
    }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`Claude ${res.status}: ${data?.error?.message || JSON.stringify(data).slice(0, 300)}`);
  }
  const textBlock = (data?.content ?? []).find((b: any) => b?.type === "text");
  if (!textBlock?.text) throw new Error("Claude returned no text content");
  const draft = validateDraft(JSON.parse(extractJson(textBlock.text)));
  if (!draft) throw new Error("Claude response did not match the expected draft shape");
  return draft;
}

async function generateWithGemini(brief: string): Promise<Draft> {
  if (!geminiKey) throw new Error("GEMINI_API_KEY not set — no fallback available");
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${geminiKey}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
        contents: [{ role: "user", parts: [{ text: brief }] }],
        generationConfig: { responseMimeType: "application/json" },
      }),
    },
  );
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`Gemini ${res.status}: ${data?.error?.message || JSON.stringify(data).slice(0, 300)}`);
  }
  const text = data?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error("Gemini returned no text content");
  const draft = validateDraft(JSON.parse(extractJson(text)));
  if (!draft) throw new Error("Gemini response did not match the expected draft shape");
  return draft;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    if (!callerId) return json({ error: "Unauthorized" }, 401);

    const { content_id } = await req.json();
    if (!content_id || typeof content_id !== "string") return json({ error: "Missing content_id" }, 400);

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: caller } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
    if (caller?.role !== "admin") return json({ error: "Admin only" }, 403);

    const { data: row, error: rowErr } = await supabase
      .from("content_items")
      .select("id, topic, keyword, audience, search_intent, category, state, research_summary")
      .eq("id", content_id)
      .maybeSingle();
    if (rowErr || !row) return json({ error: "Content item not found" }, 404);

    const brief = buildBrief(row);

    let draft: Draft;
    let model: string;
    try {
      if (!anthropicKey) throw new Error("ANTHROPIC_API_KEY not set");
      draft = await generateWithClaude(brief);
      model = "claude-sonnet-5";
    } catch (claudeErr) {
      console.error(`generate-blog-draft: Claude failed for ${content_id}, falling back to Gemini:`, claudeErr);
      draft = await generateWithGemini(brief);
      model = "gemini-2.5-flash (fallback)";
    }

    const { error: updateErr } = await supabase
      .from("content_items")
      .update({
        ...draft,
        content_status: "REVIEW",
        updated_at: new Date().toISOString(),
      })
      .eq("id", content_id);
    if (updateErr) {
      console.error("generate-blog-draft update error:", updateErr);
      return json({ error: updateErr.message }, 500);
    }

    await logAdminAction({
      adminId: callerId,
      action: "content.generate",
      targetType: "content_item",
      targetId: content_id,
      summary: `Generated a draft for "${row.topic}" via ${model}`,
      metadata: { model, topic: row.topic },
    });

    return json({ success: true, model });
  } catch (error: any) {
    console.error("generate-blog-draft error:", error);
    return json({ error: error.message }, 500);
  }
});
