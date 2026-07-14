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

async function hmacSha256(secret: string, payload: string): Promise<{ hex: string; b64: string }> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const buf = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  const bytes = new Uint8Array(buf);
  const hex = Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
  const b64 = btoa(String.fromCharCode(...bytes));
  return { hex, b64 };
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}

async function creditFunding(supabase: any, data: any) {
  // v4's success wording varies — accept the known "completed" spellings.
  const status = String(data?.status ?? "").toLowerCase();
  const SUCCESS = ["successful", "succeeded", "success", "completed", "complete", "paid"];
  if (!data || !SUCCESS.includes(status)) {
    return { ignored: true, reason: "not_successful", got_status: data?.status, amount: data?.amount };
  }
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

// Finalize a vendor/buyer withdrawal from a `transfer.disburse` event. The
// wallet was already debited when the withdrawal was requested, so SUCCESSFUL
// just confirms it; FAILED reverses the hold back into the wallet.
async function finalizeWithdrawal(supabase: any, data: any) {
  const reference = data?.reference;
  if (!reference) return { ignored: true, reason: "no_reference" };

  const { data: wd } = await supabase
    .from("withdrawals")
    .select("id, user_id, amount, status")
    .eq("flw_reference", reference)
    .maybeSingle();
  if (!wd) return { ignored: true, reason: "withdrawal_not_found" };

  const status = String(data?.status ?? "").toUpperCase();
  const amount = Number(wd.amount) || 0;

  if (status === "SUCCESSFUL") {
    if (wd.status === "success") return { alreadyProcessed: true };
    await supabase.from("withdrawals").update({ status: "success" }).eq("id", wd.id);
    try {
      await supabase.from("notifications").insert({
        user_id: wd.user_id, title: "Withdrawal sent",
        body: `₦${amount.toLocaleString()} was sent to your bank.`, type: "general",
      });
    } catch (_) { /* non-fatal */ }
    return { success: true, state: "success" };
  }

  if (status === "FAILED") {
    if (wd.status === "success" || wd.status === "failed") return { alreadyProcessed: true };
    // Reverse the hold and mark the debit ledger row failed so it stops
    // counting against the buyer's refunds-only withdrawable cap.
    await supabase.rpc("wallet_credit", {
      p_user_id: wd.user_id, p_amount: amount, p_type: "reversal",
      p_reference: `rev_${reference}`, p_description: "Withdrawal reversal (transfer failed)",
    });
    await supabase.from("wallet_transactions").update({ status: "failed" }).eq("reference", reference);
    await supabase.from("withdrawals").update({ status: "failed", failure_reason: "transfer_failed" }).eq("id", wd.id);
    try {
      await supabase.from("notifications").insert({
        user_id: wd.user_id, title: "Withdrawal failed",
        body: `Your ₦${amount.toLocaleString()} withdrawal failed and was returned to your wallet.`, type: "general",
      });
    } catch (_) { /* non-fatal */ }
    return { success: true, state: "failed" };
  }

  return { ignored: true, reason: "unhandled_status" };
}

const SUCCESS_STATUSES = ["successful", "succeeded", "success", "completed", "complete", "paid"];
const PICKUP_WINDOW_HOURS = 24;

// A Flutterwave checkout payment (tx_ref = chk...) succeeded. Create the per-
// vendor orders + escrow from the VERIFIED intent that prepare-checkout stored.
// Idempotent: an atomic claim on the pending intent row (pending -> success)
// means only ONE webhook delivery creates the orders, even though Flutterwave
// retries. Underpayments are credited to the buyer's wallet instead of shipping.
async function createOrdersFromCheckout(supabase: any, txRef: string, data: any) {
  const status = String(data?.status ?? "").toLowerCase();
  if (!SUCCESS_STATUSES.includes(status)) return { ignored: true, reason: "not_successful", got: data?.status };
  if (data.currency && data.currency !== "NGN") return { ignored: true, reason: "non_ngn" };

  // Atomic claim — only the winner (pending -> success) creates the orders.
  const { data: claimed } = await supabase
    .from("transactions")
    .update({ status: "success" })
    .eq("paystack_reference", txRef)
    .eq("status", "pending")
    .eq("type", "payment")
    .select("id, buyer_id, amount, metadata");
  if (!claimed || claimed.length === 0) return { ignored: true, reason: "already_processed_or_unknown_ref" };

  const intent = claimed[0];
  const buyer_id = intent.buyer_id as string;
  const meta = typeof intent.metadata === "string" ? JSON.parse(intent.metadata) : (intent.metadata || {});
  const enriched: any[] = meta.vendor_orders || [];
  const total = Number(meta.total ?? intent.amount) || 0;
  const paid = Number(data.amount) || 0;

  // Underpaid (e.g. a partial transfer) — don't ship. Credit what came in to the
  // buyer's wallet so they're not out of pocket, and leave for support.
  if (paid + 1 < total) {
    console.error(`checkout underpaid: ref=${txRef} paid=${paid} total=${total}`);
    await supabase.rpc("wallet_credit", {
      p_user_id: buyer_id, p_amount: paid, p_type: "fund",
      p_reference: `flw_charge_${data.id ?? txRef}`, p_provider: "flutterwave",
      p_description: "Payment received (order not completed — contact support)",
    });
    return { ignored: true, reason: "underpaid", paid, total };
  }

  const created: any[] = [];
  for (const vo of enriched) {
    const totalWithDelivery = Number(vo.subtotal) + Number(vo.delivery_fee || 0);
    const vendorPayout = vo.delivery_type === "courier" ? Number(vo.subtotal) : totalWithDelivery;
    const orderId = crypto.randomUUID();
    const reference = `flw_${orderId}`;
    const pickupDeadline = vo.delivery_type === "courier"
      ? new Date(Date.now() + PICKUP_WINDOW_HOURS * 3600 * 1000).toISOString() : null;

    const { error: orderErr } = await supabase.from("orders").insert({
      id: orderId, buyer_id, vendor_id: vo.vendor_id, store_id: vo.store_id,
      status: "paid", paid_at: new Date().toISOString(),
      items: JSON.stringify(vo.items), total: vo.subtotal,
      delivery_fee: vo.delivery_fee || 0, delivery_type: vo.delivery_type,
      vendor_delivery_contribution: vo.vendor_contribution || 0,
      total_with_delivery: totalWithDelivery, payment_reference: reference,
      delivery_quote_id: vo.delivery_quote_id, selected_courier_name: vo.selected_courier_name,
      selected_provider: vo.selected_provider, pickup_deadline: pickupDeadline,
    });
    if (orderErr) { console.error(`checkout order insert failed vendor=${vo.vendor_id}:`, orderErr); continue; }

    const { error: txInsErr } = await supabase.from("transactions").insert({
      order_id: orderId, buyer_id, vendor_id: vo.vendor_id, store_id: vo.store_id || null,
      amount: totalWithDelivery, platform_fee: 0, vendor_payout,
      paystack_reference: `tx_${orderId}`, status: "success", type: "payment",
      metadata: JSON.stringify({ funding_source: "flutterwave", checkout_ref: txRef }),
    });
    if (txInsErr) console.error(`checkout payment tx insert failed order=${orderId}:`, JSON.stringify(txInsErr));

    try {
      const { data: tok } = await supabase.from("device_tokens").select("fcm_token").eq("user_id", vo.vendor_id).maybeSingle();
      if (tok?.fcm_token) {
        await fetch(`${supabaseUrl}/functions/v1/send-push`, {
          method: "POST",
          headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({ user_id: vo.vendor_id, title: "New Order!", body: `You received a new order of ₦${totalWithDelivery.toLocaleString()}`, data: { type: "order", orderId } }),
        });
      }
    } catch (_) { /* non-fatal */ }

    // Consume the negotiated delivery fee: a chat-agreed fee is good for THIS
    // order only. Mark it "used" so the buyer's next order from this vendor
    // starts a fresh negotiation instead of silently reusing the old fee.
    if (vo.delivery_type !== "courier" && Number(vo.delivery_fee) > 0) {
      try {
        const { data: chats } = await supabase.from("chats").select("id").eq("buyer_id", buyer_id).eq("vendor_id", vo.vendor_id);
        const chatIds = (chats || []).map((c: any) => c.id);
        if (chatIds.length) {
          await supabase.from("messages").update({ delivery_fee_status: "used" }).in("chat_id", chatIds).eq("delivery_fee_status", "accepted");
        }
      } catch (_) { /* non-fatal */ }
    }
    created.push({ id: orderId, vendorId: vo.vendor_id });
  }

  try { await supabase.from("cart_items").delete().eq("buyer_id", buyer_id); } catch (_) { /* non-fatal */ }
  try {
    await fetch(`${supabaseUrl}/functions/v1/send-push`, {
      method: "POST",
      headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ user_id: buyer_id, title: "Order Confirmed!", body: `Payment received. ${created.length} order(s) confirmed.`, data: { type: "order" } }),
    });
  } catch (_) { /* non-fatal */ }

  return { success: true, orders: created, count: created.length };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const rawBody = await req.text();
    // Flutterwave has used different header names across versions; accept both.
    const sig = req.headers.get("flutterwave-signature") || req.headers.get("verif-hash") || "";

    if (!flwSecretHash) {
      console.error("FLUTTERWAVE_SECRET_HASH not configured");
      return json({ error: "server_misconfigured" }, 500);
    }

    // Accept any of the schemes Flutterwave may use: HMAC-SHA256 as hex or
    // base64, or the plain secret hash echoed back (v3-style verif-hash).
    const { hex, b64 } = await hmacSha256(flwSecretHash, rawBody);
    const valid = !!sig && (safeEqual(sig, hex) || safeEqual(sig, b64) || safeEqual(sig, flwSecretHash));
    if (!valid) {
      console.error("Invalid Flutterwave webhook signature");
      return json({ error: "Invalid signature" }, 401);
    }

    const event = JSON.parse(rawBody);
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const eventName = event.event || event.type || event["event.type"];
    const data = event.data ?? event;

    if (eventName === "charge.completed" || event["event.type"] === "BANK_TRANSFER_TRANSACTION") {
      // A checkout payment carries our tx_ref (chk...); anything else is a buyer
      // funding their wallet via their permanent virtual account.
      const ref = String(data.tx_ref || data.reference || "");
      if (ref.startsWith("chk")) {
        const result = await createOrdersFromCheckout(supabase, ref, data);
        console.log("checkout result:", JSON.stringify(result));
      } else {
        const result = await creditFunding(supabase, data);
        console.log("funding result:", JSON.stringify(result));
      }
    } else if (eventName === "transfer.disburse" || eventName === "transfer.completed") {
      const result = await finalizeWithdrawal(supabase, data);
      console.log("withdrawal result:", JSON.stringify(result));
    } else {
      // Ack anything else so Flutterwave stops retrying.
      console.log(`Unhandled Flutterwave event: ${eventName}`);
    }

    return json({ success: true });
  } catch (error: any) {
    console.error("flutterwave-webhook error:", error);
    return json({ error: error.message }, 500);
  }
});
