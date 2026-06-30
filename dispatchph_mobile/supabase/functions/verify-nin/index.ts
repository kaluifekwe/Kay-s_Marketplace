import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Buyer KYC: verify a NIN with an identity provider, then mark the caller
// kyc_status='verified'. Authenticated (the caller is the buyer being verified
// — we act on auth.uid(), never a client-supplied id). The provider call +
// the kyc_status write both happen server-side with the service role.
//
// Provider adapter: DOJAH by default (common NIN provider in Nigeria). To swap
// to YouVerify/Prembly/Smile ID, replace verifyNinWithProvider() — the rest is
// provider-agnostic. Secrets: DOJAH_API_KEY, DOJAH_APP_ID.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

const dojahApiKey = Deno.env.get("DOJAH_API_KEY") ?? "";
const dojahAppId = Deno.env.get("DOJAH_APP_ID") ?? "";
const dojahBase = Deno.env.get("DOJAH_BASE_URL") ?? "https://api.dojah.io";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

function callerId(authHeader: string | null): string | null {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return null;
  const token = authHeader.replace("Bearer ", "");
  if (!token || token === supabaseAnonKey) return null;
  try {
    const p = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    if (p.exp && p.exp < Math.floor(Date.now() / 1000)) return null;
    return p.sub || null;
  } catch {
    return null;
  }
}

function norm(s: string): string {
  return (s ?? "").toLowerCase().replace(/[^a-z]/g, "");
}

const providerConfigured = !!(dojahApiKey && dojahAppId);

// Returns { ok, record?, reason? }. Swap this function to change provider.
async function verifyNinWithProvider(nin: string): Promise<{ ok: boolean; record?: any; reason?: string }> {
  const res = await fetch(`${dojahBase}/api/v1/kyc/nin?nin=${encodeURIComponent(nin)}`, {
    headers: { Authorization: dojahApiKey, AppId: dojahAppId },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body?.entity) {
    return { ok: false, reason: body?.error || `Provider rejected NIN (${res.status})` };
  }
  return { ok: true, record: body.entity };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

    const uid = callerId(req.headers.get("Authorization"));
    if (!uid) return json({ error: "Authentication required" }, 401);

    const { nin, first_name, last_name } = await req.json();
    if (!nin || !/^\d{11}$/.test(String(nin))) {
      return json({ error: "Enter a valid 11-digit NIN" }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Already verified? idempotent success.
    const { data: me } = await supabase
      .from("users")
      .select("kyc_status, name")
      .eq("id", uid)
      .maybeSingle();
    if (me?.kyc_status === "verified") return json({ success: true, status: "verified" });

    // One account per NIN — reject if another account already verified with it.
    const { data: clash } = await supabase
      .from("users")
      .select("id")
      .eq("nin", String(nin))
      .eq("kyc_status", "verified")
      .neq("id", uid)
      .maybeSingle();
    if (clash) {
      return json({ error: "This NIN is already linked to another account." }, 409);
    }

    // Real verification only when a provider is configured (paid). Without it we
    // run in free mode: 11-digit format + uniqueness only (see notes above).
    if (providerConfigured) {
      const result = await verifyNinWithProvider(String(nin));
      if (!result.ok) {
        await supabase.from("users").update({ kyc_status: "rejected" }).eq("id", uid);
        return json({ error: result.reason || "NIN verification failed", status: "rejected" }, 400);
      }
      // Lenient name match: provider first/last should resemble the account/claimed name.
      const rec = result.record || {};
      const provFirst = norm(rec.first_name || rec.firstname || "");
      const provLast = norm(rec.last_name || rec.surname || rec.lastname || "");
      const claimed = norm(`${first_name ?? ""} ${last_name ?? ""}` + " " + (me?.name ?? ""));
      if ((provFirst || provLast) && claimed) {
        const matches = (provFirst && claimed.includes(provFirst)) || (provLast && claimed.includes(provLast));
        if (!matches) {
          await supabase.from("users").update({ kyc_status: "rejected" }).eq("id", uid);
          return json({ error: "NIN name does not match your account name", status: "rejected" }, 400);
        }
      }
    }

    const { error: upErr } = await supabase
      .from("users")
      .update({
        nin: String(nin),
        kyc_status: "verified",
        kyc_verified_at: new Date().toISOString(),
      })
      .eq("id", uid);
    if (upErr) {
      // Unique-index race: the NIN got linked to another account first.
      return json({ error: "This NIN is already linked to another account." }, 409);
    }

    return json({ success: true, status: "verified" });
  } catch (e: any) {
    console.error("verify-nin error:", e);
    return json({ error: e.message || "Verification error" }, 500);
  }
});
