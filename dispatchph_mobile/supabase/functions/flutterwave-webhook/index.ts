import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Receives Flutterwave v4 webhooks. Phase 2 handles virtual-account funding:
// when a buyer transfers into their permanent VA, Flutterwave sends
// `charge.completed` (event.type BANK_TRANSFER_TRANSACTION) and we credit the
// buyer's wallet, idempotent on the Flutterwave transaction id. `transfer.*`
// events (vendor withdrawals) are handled in Phase 4.
//
// v4 signs webhooks: the `flutterwave-signature` header is HMAC-SHA256 of the
// raw request body, keyed by the Secret Hash you set in the dashboard. A valid
// signature proves authenticity, so we credit straight from the signed payload
// (no extra verify round-trip).

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const flwSecretHash = Deno.env.get("FLUTTERWAVE_SECRET_HASH") || "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, flutterwave-signature",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function hmacSha256Hex(secret: string, payload: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}

async function creditFunding(supabase: any, data: any) {
  if (!data || data.status !== "successful") return { ignored: true, reason: "not_successful" };
  if (data.currency && data.currency !== "NGN") return { ignored: true, reason: "non_ngn" };

  const amount = Number(data.amount) || 0;
  if (amount <= 0) return { ignored: true, reason: "zero_amount" };

  // Map the payment to a buyer: primary by the customer email the VA was
  // created with; fallback to the `wallet_<userId>_<ts>` tx_ref/reference.
  const email: string | undefined = data.customer?.email;
  let userId: string | null = null;
  if (email) {
    const { data: u } = await supabase.from("users").select("id").eq("email", email).maybeSingle();
    userId = u?.id ?? null;
  }
  if (!userId) {
    const ref = String(data.tx_ref || data.reference || "");
    if (ref.startsWith("wallet_")) userId = ref.substring("wallet_".length).split("_")[0];
  }
  if (!userId) return { ignored: true, reason: "buyer_not_found" };

  const txId = data.id ?? data.tx_ref ?? data.reference;
  const { error } = await supabase.rpc("wallet_credit", {
    p_user_id: userId,
    p_amount: amount,
    p_type: "fund",
    p_reference: `flw_charge_${txId}`,
    p_provider: "flutterwave",
    p_provider_ref: String(txId),
    p_description: "Wallet funding",
  });
  if (error) {
    console.error("wallet_credit error:", error);
    return { error: error.message };
  }

  try {
    await supabase.from("notifications").insert({
      user_id: userId,
      title: "Wallet funded",
      body: `₦${amount.toLocaleString()} was added to your wallet.`,
      type: "general",
    });
  } catch (_) { /* non-fatal */ }

  return { success: true, credited: amount, userId };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const rawBody = await req.text();
    const signature = req.headers.get("flutterwave-signature") || "";

    if (!flwSecretHash) {
      console.error("FLUTTERWAVE_SECRET_HASH not configured");
      return json({ error: "server_misconfigured" }, 500);
    }
    const expected = await hmacSha256Hex(flwSecretHash, rawBody);
    // HMAC-SHA256 signed value; also accept a plain secret-hash match for
    // dashboards configured the legacy (v3-style verif-hash) way.
    if (!signature || (!safeEqual(signature, expected) && !safeEqual(signature, flwSecretHash))) {
      console.error("Invalid Flutterwave webhook signature");
      return json({ error: "Invalid signature" }, 401);
    }

    const event = JSON.parse(rawBody);
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const eventName = event.event || event.type || event["event.type"];
    const data = event.data ?? event;

    if (eventName === "charge.completed" || event["event.type"] === "BANK_TRANSFER_TRANSACTION") {
      const result = await creditFunding(supabase, data);
      console.log("funding result:", JSON.stringify(result));
    } else {
      // transfer.* (withdrawals) handled in Phase 4; ack the rest so Flutterwave
      // stops retrying.
      console.log(`Unhandled Flutterwave event: ${eventName}`);
    }

    return json({ success: true });
  } catch (error: any) {
    console.error("flutterwave-webhook error:", error);
    return json({ error: error.message }, 500);
  }
});
