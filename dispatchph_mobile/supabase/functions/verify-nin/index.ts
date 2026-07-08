import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Buyer KYC: verify a NIN with an identity provider, then mark the caller
// kyc_status='verified'. Authenticated (the caller is the buyer being verified
// — we act on auth.uid(), never a client-supplied id). The provider call +
// the kyc_status write both happen server-side with the service role.
//
// Provider adapter: PREMBLY (IdentityPass). To swap providers, replace
// verifyNinWithProvider() — the rest is provider-agnostic. Secrets:
// PREMBLY_X_API_KEY, PREMBLY_APP_ID (optional PREMBLY_BASE_URL).

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

const premblyApiKey = Deno.env.get("PREMBLY_X_API_KEY") ?? "";
const premblyAppId = Deno.env.get("PREMBLY_APP_ID") ?? "";
const premblyBase = Deno.env.get("PREMBLY_BASE_URL") ?? "https://api.prembly.com";

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

const providerConfigured = !!(premblyApiKey && premblyAppId);

// Prembly (IdentityPass) NIN verification. Returns { ok, record?, reason? }.
// Swap this function to change provider. Logs the raw response once so the exact
// field paths can be confirmed on the first real call.
async function verifyNinWithProvider(nin: string): Promise<{ ok: boolean; record?: any; reason?: string }> {
  const res = await fetch(`${premblyBase}/identitypass/verification/nin`, {
    method: "POST",
    headers: {
      "x-api-key": premblyApiKey,
      "app-id": premblyAppId,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({ number: nin }),
  });
  const body = await res.json().catch(() => ({}));
  console.log(`prembly nin resp: status=${res.status} body=${JSON.stringify(body).slice(0, 800)}`);

  const rec = body?.nin_data ?? body?.data ?? body;
  const verified =
    body?.status === true ||
    String(body?.status ?? "").toLowerCase() === "success" ||
    String(body?.verification?.status ?? "").toUpperCase().includes("VERIFIED");
  if (!res.ok || !verified || !rec) {
    return { ok: false, reason: body?.detail || body?.message || `NIN verification failed (${res.status})` };
  }
  return { ok: true, record: rec };
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

    // Real name-matched verification runs ONLY when the provider is configured
    // (paid). For now (no key) we're in FREE mode: 11-digit format +
    // one-account-per-NIN uniqueness. Add DOJAH_API_KEY/DOJAH_APP_ID later and
    // name matching switches on automatically — no code change.
    if (providerConfigured) {
      const result = await verifyNinWithProvider(String(nin));
      if (!result.ok) {
        await supabase.from("users").update({ kyc_status: "rejected" }).eq("id", uid);
        return json({ error: result.reason || "NIN verification failed", status: "rejected" }, 400);
      }
      // Require BOTH first name and surname to match the NIN's registered names.
      const rec = result.record || {};
      const provFirst = norm(rec.first_name || rec.firstname || "");
      const provLast = norm(rec.last_name || rec.surname || rec.lastname || "");
      const claimed = norm(`${first_name ?? ""} ${last_name ?? ""} ${me?.name ?? ""}`);
      const firstOk = provFirst.length > 0 && claimed.includes(provFirst);
      const lastOk = provLast.length > 0 && claimed.includes(provLast);
      if (!firstOk || !lastOk) {
        await supabase.from("users").update({ kyc_status: "rejected" }).eq("id", uid);
        return json({ error: "The name on this NIN doesn't match your account name.", status: "rejected" }, 400);
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
