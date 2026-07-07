import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Receives Flutterwave webhooks. Phase 2 handles `charge.completed` for virtual
// account funding — when a buyer transfers into their permanent VA, we credit
// their wallet (idempotent on the Flutterwave transaction id). `transfer.*`
// events (vendor withdrawals) are handled in Phase 4.
//
// Flutterwave authenticates webhooks with a shared secret: it sends the exact
// value of your dashboard "Secret hash" in the `verif-hash` header. We compare
// it (constant-time) to FLUTTERWAVE_SECRET_HASH. We then RE-VERIFY the
// transaction against Flutterwave's API before crediting — the webhook body
// alone is never trusted for amount/status.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const flwSecretKey = Deno.env.get("FLUTTERWAVE_SECRET_KEY")!;
const flwSecretHash = Deno.env.get("FLUTTERWAVE_SECRET_HASH")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, verif-hash",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// Constant-time string compare so a mismatched hash can't be timed.
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}

// Credit the buyer's wallet for a confirmed VA funding transaction.
async function processFunding(supabase: any, txId: string | number) {
  // Re-verify with Flutterwave — the webhook body is not trusted for money.
  const verifyRes = await fetch(
    `https://api.flutterwave.com/v3/transactions/${encodeURIComponent(String(txId))}/verify`,
    { headers: { Authorization: `Bearer ${flwSecretKey}` } }
  );
  const verify = await verifyRes.json();

  if (verify.status !== "success" || verify.data?.status !== "successful") {
    return { ignored: true, reason: "not_successful" };
  }

  const data = verify.data;
  if (data.currency && data.currency !== "NGN") {
    return { ignored: true, reason: "non_ngn" };
  }

  const amount = Number(data.amount) || 0;
  if (amount <= 0) return { ignored: true, reason: "zero_amount" };

  // Map the payment to a buyer. Primary: the customer email the VA was created
  // with. Fallback: tx_ref of the form `wallet_<userId>` we set at VA creation.
  const email: string | undefined = data.customer?.email;
  let userId: string | null = null;

  if (email) {
    const { data: u } = await supabase.from("users").select("id").eq("email", email).maybeSingle();
    userId = u?.id ?? null;
  }
  if (!userId && typeof data.tx_ref === "string" && data.tx_ref.startsWith("wallet_")) {
    userId = data.tx_ref.substring("wallet_".length);
  }
  if (!userId) return { ignored: true, reason: "buyer_not_found" };

  // Idempotent credit — keyed on the Flutterwave transaction id, so a replayed
  // or duplicated webhook never double-credits.
  const reference = `flw_charge_${data.id ?? txId}`;
  const { error } = await supabase.rpc("wallet_credit", {
    p_user_id: userId,
    p_amount: amount,
    p_type: "fund",
    p_reference: reference,
    p_provider: "flutterwave",
    p_provider_ref: String(data.flw_ref ?? data.id ?? txId),
    p_description: "Wallet funding",
  });
  if (error) {
    console.error("wallet_credit error:", error);
    return { error: error.message };
  }

  // Nudge the buyer that funds landed (best-effort).
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
    const signature = req.headers.get("verif-hash") || "";
    if (!signature || !flwSecretHash || !safeEqual(signature, flwSecretHash)) {
      console.error("Invalid Flutterwave webhook signature");
      return json({ error: "Invalid signature" }, 401);
    }

    const rawBody = await req.text();
    const event = JSON.parse(rawBody);
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Flutterwave sends `event: "charge.completed"` with `data.status`.
    const eventType = event.event || event["event.type"];
    if (eventType === "charge.completed" && event.data?.id) {
      const result = await processFunding(supabase, event.data.id);
      console.log("charge.completed result:", JSON.stringify(result));
    } else {
      // transfer.* (withdrawals) handled in Phase 4; ack everything else so
      // Flutterwave doesn't retry indefinitely.
      console.log(`Unhandled Flutterwave event: ${eventType}`);
    }

    return json({ success: true });
  } catch (error: any) {
    console.error("flutterwave-webhook error:", error);
    return json({ error: error.message }, 500);
  }
});
