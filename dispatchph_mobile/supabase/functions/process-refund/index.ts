import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const paystackSecretKey = Deno.env.get("PAYSTACK_SECRET_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function isServiceRoleCall(authHeader: string | null): boolean {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return false;
  return authHeader.replace("Bearer ", "") === supabaseServiceKey;
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

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({ error: "Method not allowed" }), {
        status: 405,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    const { order_id, dispute_id, reason, refund_method } = await req.json();

    if (!order_id) {
      return new Response(
        JSON.stringify({ error: "Missing required field: order_id" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("id, buyer_id, vendor_id, store_id, status, payment_reference, delivery_type, total, total_with_delivery, delivery_fee, delivered_at, has_shipbubble_delivery, payment_released")
      .eq("id", order_id)
      .maybeSingle();

    if (orderError || !order) {
      return new Response(
        JSON.stringify({ error: "Order not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const serviceRoleCall = isServiceRoleCall(req.headers.get("Authorization"));
    let isAdminCaller = false;
    if (!serviceRoleCall && callerId && callerId !== order.buyer_id) {
      const { data: callerUser } = await supabase
        .from("users")
        .select("role")
        .eq("id", callerId)
        .maybeSingle();
      isAdminCaller = callerUser?.role === "admin";
    }

    if (!serviceRoleCall && (!callerId || (callerId !== order.buyer_id && !isAdminCaller))) {
      return new Response(
        JSON.stringify({ error: "Only the buyer or an admin can request a refund" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // A buyer cannot self-cancel once a rider has been booked: the courier fee is
    // already committed and the rider is on the way, so cancellation is closed —
    // the buyer waits for delivery or opens a dispute. (dispute_id is the dispute
    // path; admin/service-role can still override for support cases.)
    const riderBooked = order.delivery_type === "courier" && order.has_shipbubble_delivery === true;
    if (!dispute_id && riderBooked && !serviceRoleCall && !isAdminCaller) {
      return new Response(
        JSON.stringify({
          error: "A rider has already been booked for this order, so it can no longer be cancelled. If there's a problem with the delivery, please report an issue once it ships.",
        }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Strict dispute flow refunds happen after delivery is confirmed (status
    // 'confirmed'/'auto_released'), not just pre-delivery ('paid'/'shipped').
    // Note: if escrow already released the vendor payout, this refund is
    // funded by the platform (no clawback) — consistent with the no-commission
    // launch model where the platform absorbs early dispute costs.
    const refundableStatuses = dispute_id
      ? ["paid", "shipped", "refund_requested", "confirmed", "auto_released", "delivery_failed"]
      : ["paid", "shipped", "refund_requested", "delivery_failed"];
    if (!refundableStatuses.includes(order.status)) {
      return new Response(
        JSON.stringify({ error: `Cannot refund order with status: ${order.status}` }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Check if already refunded
    const { data: existingRefund } = await supabase
      .from("transactions")
      .select("id")
      .eq("order_id", order_id)
      .eq("type", "refund")
      .eq("status", "success")
      .maybeSingle();

    if (existingRefund) {
      return new Response(
        JSON.stringify({ success: true, message: "Already refunded" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Atomically claim this refund so two concurrent calls for the same
    // order can't both pass the checks above and both trigger a gateway
    // refund/transfer.
    const originalStatus = order.status;
    const { data: claimed, error: claimError } = await supabase
      .from("orders")
      .update({ status: "refund_processing" })
      .eq("id", order_id)
      .in("status", refundableStatuses)
      .select("id");

    if (claimError) {
      return new Response(
        JSON.stringify({ error: "Failed to claim refund" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!claimed || claimed.length === 0) {
      return new Response(
        JSON.stringify({ success: true, message: "Refund already in progress" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: tx } = await supabase
      .from("transactions")
      .select("*")
      .eq("order_id", order_id)
      .eq("status", "success")
      .eq("type", "payment")
      .maybeSingle();

    // Don't hard-require a payment transaction. Some orders never got one (an
    // older order, or a webhook whose payment-tx insert failed) — refusing to
    // refund those left buyers stuck and disputes un-closable ("refund failed").
    // Fall back to the order's own amount, exactly like release-escrow computes
    // the payout from the order.

    // Once a COURIER order has actually been delivered, the courier was used and
    // the delivery fee was earned — a post-delivery dispute refunds the ITEM
    // value only, not the delivery fee. Before delivery (incl. "not received"),
    // or for vendor-handled delivery, the full amount is refundable.
    const courierDelivered = order.delivery_type === "courier" && order.delivered_at != null;
    // A courier that PICKED UP but then failed to deliver (e.g. buyer unreachable)
    // still spent the fee + return trip — so the buyer's refund is item-value
    // only, delivery forfeited, exactly like a delivered courier order. Checked
    // from the delivery row so it survives the order status changing to
    // refund_requested when the buyer reports the issue.
    let deliveryAttempted = false;
    if (order.delivery_type === "courier" && !courierDelivered) {
      const { data: del } = await supabase
        .from("deliveries")
        .select("picked_up_at, status")
        .eq("order_id", order_id)
        .maybeSingle();
      deliveryAttempted = !!del?.picked_up_at && ["failed", "cancelled"].includes(del?.status);
    }
    const orderPaid = Number(order.total_with_delivery ?? order.total) || 0;
    const itemSubtotal = Number(order.total) || 0;
    const refundAmount = (courierDelivered || deliveryAttempted)
      ? itemSubtotal
      : (tx ? Number(tx.amount) : orderPaid);
    // Refund to the SOURCE the order was funded from.
    //
    // A credit-funded order MUST refund to kays_credit and never to the wallet.
    // The wallet is withdrawable to a real bank account (wallet-withdraw), while
    // Kay's Credit is spend-only — so sending a credit-funded refund to the wallet
    // converts platform-funded credit into cash: sign up -> ₦200 welcome credit
    // (grant_welcome_credit) -> buy with credit (complete-credit-order funds it
    // from our own balance) -> refund -> withdraw. Free money, and the delivery
    // auto-refund in _shared/delivery/apply-status.ts triggers it with no human
    // involved. complete-credit-order records the source on the payment
    // transaction; payment_reference ('credit_…') covers rows whose tx is missing.
    //
    // Credit orders are all-or-nothing (complete-credit-order rejects partial
    // credit + card), so a single source per order is sound today. Revisit if
    // split payments land.
    let fundingSource: string | null = null;
    try {
      const rawMeta = (tx as any)?.metadata;
      const meta = typeof rawMeta === "string" ? JSON.parse(rawMeta) : rawMeta;
      fundingSource = meta?.funding_source ?? null;
    } catch {
      // Malformed metadata must never block a refund — fall back to the reference.
    }
    const creditFunded = fundingSource === "kays_credit" ||
      String(order.payment_reference ?? "").startsWith("credit_");

    // The destination is decided by the FUNDING SOURCE, never by the caller.
    //
    // Callers historically hardcoded "credit" (buyer cancel in order_bloc, the
    // dispute auto-timeout in auto-release-escrow, expire-unbooked-pickups, …).
    // That sent WALLET- and CARD-funded money into spend-only Kay's Credit: the
    // buyer paid real money, cancelled, and could no longer get it back out.
    // Deciding here — rather than trusting each caller — fixes every path at
    // once and can't regress when a new caller is added.
    //
    //   credit-funded -> credit  (must NEVER reach the withdrawable wallet, or
    //                             platform-granted credit becomes cash)
    //   wallet-funded -> wallet  (it came from there; caller cannot override)
    //   otherwise     -> wallet, unless an admin deliberately asks for a
    //                    bank/card payout (support cases keep that escape hatch)
    let method: string;
    if (creditFunded) {
      method = "credit";
    } else if (fundingSource === "wallet") {
      method = "wallet";
    } else if (refund_method === "bank" || refund_method === "card") {
      method = refund_method;
    } else {
      method = "wallet";
    }
    if (refund_method && refund_method !== method) {
      console.log(
        `process-refund: order ${order_id} funding_source='${fundingSource ?? "unknown"}' ` +
        `-> refunding to '${method}' (caller requested '${refund_method}')`,
      );
    }
    let refundReference = "";

    if (method === "credit") {
      // Atomic increment, not read-then-update: a cashback grant landing between
      // the read and the write would be silently overwritten. (Concurrent refunds
      // of the SAME order are already prevented by the refund_processing claim
      // above; this guards against any OTHER writer of kays_credit.)
      const { error: creditErr } = await supabase.rpc("increment_kays_credit", {
        p_user_id: order.buyer_id,
        p_amount: refundAmount,
      });
      if (creditErr) {
        console.error("process-refund increment_kays_credit error:", creditErr);
        // Release the claim so the buyer can retry instead of being stuck in
        // refund_processing with no money back.
        await supabase.from("orders").update({ status: originalStatus }).eq("id", order_id);
        return new Response(
          JSON.stringify({ error: "Failed to credit refund" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const expiresAt = new Date();
      expiresAt.setDate(expiresAt.getDate() + 90);

      await supabase.from("credit_transactions").insert({
        buyer_id: order.buyer_id,
        amount: refundAmount,
        type: "refund",
        order_id,
        description: `Refund for order ${order_id.substring(0, 8)}`,
        expires_at: expiresAt.toISOString(),
      });

      refundReference = `credit_${order_id}`;

    } else if (method === "wallet") {
      // Credit the buyer's WALLET (provider-agnostic, instant). Idempotent on
      // the order-based reference, so a retried refund never double-credits.
      const { error: refundErr } = await supabase.rpc("wallet_credit", {
        p_user_id: order.buyer_id,
        p_amount: refundAmount,
        p_type: "refund",
        p_reference: `refund_${order_id}`,
        p_order_id: order_id,
        p_description: `Refund for order ${order_id.substring(0, 8)}`,
      });
      if (refundErr) {
        console.error("wallet_credit (refund) error:", refundErr);
        await supabase.from("orders").update({ status: originalStatus }).eq("id", order_id);
        return new Response(
          JSON.stringify({ error: "Failed to credit wallet refund" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      refundReference = `refund_${order_id}`;

    } else if (method === "bank") {
      // Paystack transfer to buyer bank account
      const { data: buyerBank } = await supabase
        .from("buyer_bank_accounts")
        .select("paystack_recipient_code, bank_name, account_number")
        .eq("buyer_id", order.buyer_id)
        .maybeSingle();

      if (!buyerBank || !buyerBank.paystack_recipient_code) {
        await supabase.from("orders").update({ status: originalStatus }).eq("id", order_id);
        return new Response(
          JSON.stringify({ error: "No bank account on file. Please add one in Profile first." }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const transferResponse = await fetch("https://api.paystack.co/transfer", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${paystackSecretKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          source: "balance",
          amount: Math.round(refundAmount * 100),
          recipient: buyerBank.paystack_recipient_code,
          reason: `Refund for order ${order_id.substring(0, 8)} - Kays Market`,
          reference: `refund_${order_id}`,
        }),
      });

      const transferData = await transferResponse.json();

      if (!transferData.status) {
        console.error("Bank transfer refund error:", transferData);
        await supabase.from("orders").update({ status: originalStatus }).eq("id", order_id);
        return new Response(
          JSON.stringify({ error: transferData.message || "Bank transfer failed" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      refundReference = transferData.data.reference;

    } else {
      // Card refund via Paystack
      const refundResponse = await fetch("https://api.paystack.co/refund", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${paystackSecretKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          transaction: order.payment_reference || tx?.paystack_reference,
          amount: Math.round(refundAmount * 100),
          reason: reason || "Dispute resolved in buyer's favor",
          merchant_note: `Refund for order ${order_id.substring(0, 8)}${dispute_id ? `, dispute: ${dispute_id}` : ""}`,
        }),
      });

      const refundData = await refundResponse.json();

      if (!refundData.status) {
        console.error("Paystack refund error:", refundData);
        await supabase.from("orders").update({ status: originalStatus }).eq("id", order_id);
        return new Response(
          JSON.stringify({ error: refundData.message || "Refund failed" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      refundReference = refundData.data.reference || `ref_${order_id}`;
    }

    // Record refund transaction
    await supabase.from("transactions").insert({
      order_id,
      buyer_id: order.buyer_id,
      vendor_id: order.vendor_id,
      store_id: order.store_id,
      amount: refundAmount,
      status: "success",
      type: "refund",
      paystack_reference: refundReference,
      metadata: JSON.stringify({
        refund_method: method,
        dispute_id: dispute_id || null,
        reason: reason || null,
      }),
    });

    // H2 — Vendor clawback. If the vendor was ALREADY paid for this order, the
    // buyer's refund came out of the platform's pocket. Recover it from the
    // vendor's wallet (up to their balance); any shortfall becomes a pending
    // vendor_charge that release-escrow nets off their next payout. Atomic and
    // idempotent on the reference, so a retried refund never double-claws.
    // Non-fatal: the buyer is already refunded either way.
    if (order.payment_released === true) {
      const { data: cb, error: cbErr } = await supabase.rpc("wallet_clawback", {
        p_vendor_id: order.vendor_id,
        p_amount: refundAmount,
        p_reference: `clawback_${order_id}`,
        p_order_id: order_id,
        p_reason: "dispute_refund_shortfall",
      });
      if (cbErr) console.error("wallet_clawback error:", cbErr);
      else console.log(`clawback order=${order_id}:`, JSON.stringify(cb));
    }

    // Update order status
    await supabase
      .from("orders")
      .update({
        status: "refunded",
        refunded_at: new Date().toISOString(),
      })
      .eq("id", order_id);

    // Update dispute if exists, and release any vendor payout hold that was
    // reserving money for this refund. release_dispute_payout_hold is atomic
    // (M2) and idempotent (claims disputes.payout_hold_released once), so the
    // hold is decremented exactly once even if another path also calls it.
    if (dispute_id) {
      await supabase
        .from("disputes")
        .update({
          status: "resolved",
          resolution_type: "refund",
          resolved_at: new Date().toISOString(),
        })
        .eq("id", dispute_id);

      const { error: relErr } = await supabase.rpc("release_dispute_payout_hold", { p_dispute_id: dispute_id });
      if (relErr) console.error("release_dispute_payout_hold error:", relErr);
    }

    console.log(`Refund processed: order=${order_id}, amount=${refundAmount}, method=${method}`);

    return new Response(
      JSON.stringify({
        success: true,
        amount_refunded: refundAmount,
        refund_method: method,
        refund_reference: refundReference,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: any) {
    console.error("Edge function error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
