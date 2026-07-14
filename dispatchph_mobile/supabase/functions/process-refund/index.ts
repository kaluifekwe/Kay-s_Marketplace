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
      ? ["paid", "shipped", "refund_requested", "confirmed", "auto_released"]
      : ["paid", "shipped", "refund_requested"];
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
    const orderPaid = Number(order.total_with_delivery ?? order.total) || 0;
    const itemSubtotal = Number(order.total) || 0;
    const refundAmount = courierDelivered
      ? itemSubtotal
      : (tx ? Number(tx.amount) : orderPaid);
    // Refunds now default to the buyer's WALLET. card/bank/credit remain
    // available when explicitly requested (e.g. legacy card-paid orders).
    const method = refund_method || "wallet";
    let refundReference = "";

    if (method === "credit") {
      // Add to kays_credit instantly
      const { data: user } = await supabase
        .from("users")
        .select("kays_credit")
        .eq("id", order.buyer_id)
        .maybeSingle();

      const currentCredit = user?.kays_credit || 0;
      await supabase
        .from("users")
        .update({ kays_credit: currentCredit + refundAmount })
        .eq("id", order.buyer_id);

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
