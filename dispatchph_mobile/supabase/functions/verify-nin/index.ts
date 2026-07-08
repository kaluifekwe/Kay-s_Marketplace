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

// Prembly's endpoints authenticate with x-api-key; app-id is sent only when
// provided (some accounts require it, some don't) — so the key alone enables it.
const providerConfigured = !!premblyApiKey;

// Prembly (IdentityPass) identity verification for NIN or BVN. Both use the same
// request/response shape — only the path segment differs
// (/identitypass/verification/{nin|bvn}). Returns { ok, record?, reason? }.
// Logs the raw response once so exact field paths can be confirmed on first call.
async function verifyIdWithProvider(
  number: string,
  idType: "nin" | "bvn",
): Promise<{ ok: boolean; record?: any; reason?: string }> {
  const label = idType.toUpperCase();
  const res = await fetch(`${premblyBase}/identitypass/verification/${idType}`, {
    method: "POST",
    headers: {
      "x-api-key": premblyApiKey,
      ...(premblyAppId ? { "app-id": premblyAppId } : {}),
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({ number }),
  });
  const body = await res.json().catch(() => ({}));
  console.log(`prembly ${idType} resp: status=${res.status} body=${JSON.stringify(body).slice(0, 800)}`);

  const rec = body?.[`${idType}_data`] ?? body?.data ?? body;
  const verified =
    body?.status === true ||
    String(body?.status ?? "").toLowerCase() === "success" ||
    String(body?.verification?.status ?? "").toUpperCase().includes("VERIFIED");
  if (!res.ok || !verified || !rec) {
    return { ok: false, reason: body?.detail || body?.message || `${label} verification failed (${res.status})` };
  }
  return { ok: true, record: rec };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

    const uid = callerId(req.headers.get("Authorization"));
    if (!uid) return json({ error: "Authentication required" }, 401);

    const { nin, first_name, last_name, id_type } = await req.json();
    // Buyer may verify with either their NIN or their BVN (both 11 digits).
    const idType: "nin" | "bvn" = String(id_type ?? "nin").toLowerCase() === "bvn" ? "bvn" : "nin";
    const label = idType.toUpperCase();
    if (!nin || !/^\d{11}$/.test(String(nin))) {
      return json({ error: `Enter a valid 11-digit ${label}` }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Already verified? idempotent success.
    const { data: me } = await supabase
      .from("users")
      .select("kyc_status, name")
      .eq("id", uid)
      .maybeSingle();
    if (me?.kyc_status === "verified") return json({ success: true, status: "verified" });

    // One account per identity number — reject if another account already
    // verified with it. NIN and BVN both land in the `nin` column.
    const { data: clash } = await supabase
      .from("users")
      .select("id")
      .eq("nin", String(nin))
      .eq("kyc_status", "verified")
      .neq("id", uid)
      .maybeSingle();
    if (clash) {
      return json({ error: `This ${label} is already linked to another account.` }, 409);
    }

    // Real name-matched verification runs ONLY when the provider is configured
    // (paid). Without a key we're in FREE mode: 11-digit format +
    // one-account-per-number uniqueness. Set PREMBLY_X_API_KEY and name matching
    // switches on automatically — no code change.
    if (providerConfigured) {
      const result = await verifyIdWithProvider(String(nin), idType);
      if (!result.ok) {
        await supabase.from("users").update({ kyc_status: "rejected" }).eq("id", uid);
        return json({ error: result.reason || `${label} verification failed`, status: "rejected" }, 400);
      }
      // Require BOTH the provider's first name and surname to appear in the
      // name the buyer typed (primary) plus their account name. We match the
      // typed legal name so a display nickname alone can't block verification.
      // Field names vary by provider/ID type — cover snake_case + camelCase.
      const rec = result.record || {};
      const provFirst = norm(rec.first_name || rec.firstname || rec.firstName || "");
      const provLast = norm(rec.last_name || rec.surname || rec.lastname || rec.lastName || rec.surName || "");
      const claimed = norm(`${first_name ?? ""} ${last_name ?? ""} ${me?.name ?? ""}`);
      const firstOk = provFirst.length > 0 && claimed.includes(provFirst);
      const lastOk = provLast.length > 0 && claimed.includes(provLast);
      console.log(
        `name-match: provFirst=${provFirst} provLast=${provLast} claimed=${claimed} firstOk=${firstOk} lastOk=${lastOk}`,
      );
      if (!firstOk || !lastOk) {
        await supabase.from("users").update({ kyc_status: "rejected" }).eq("id", uid);
        return json({
          error: `The name on this ${label} doesn't match the name you entered. Enter your first name and surname exactly as they appear on your ${label}.`,
          status: "rejected",
        }, 400);
      }
    }

    // Adopt the verified legal name onto the account so it always matches the
    // ID — buyers often sign up with a nickname. Uses the first/surname they
    // entered (which we just matched against the ID). `name` here is the
    // personal name only; a vendor's store display (shop_name) is separate.
    const titleCase = (s: string) =>
      s.trim().replace(/\s+/g, " ").replace(/\S+/g, (w) => w[0].toUpperCase() + w.slice(1).toLowerCase());
    const verifiedName = titleCase(`${first_name ?? ""} ${last_name ?? ""}`);

    const { error: upErr } = await supabase
      .from("users")
      .update({
        nin: String(nin),
        kyc_status: "verified",
        kyc_verified_at: new Date().toISOString(),
        ...(verifiedName ? { name: verifiedName } : {}),
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
