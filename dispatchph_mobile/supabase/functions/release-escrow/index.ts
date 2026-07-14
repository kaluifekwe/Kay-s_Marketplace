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

function isServiceRoleCall(authHeader: string | null): boolean {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return false;
  return authHeader.replace("Bearer ", "") === supabaseServiceKey;
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

    const { order_id } = await req.json();

    if (!order_id) {
      return new Response(
        JSON.stringify({ error: "Missing required field: order_id" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("id, buyer_id, vendor_id, store_id, status, payment_released, total, total_with_delivery, delivery_type, has_dispute, payout_attempts")
      .eq("id", order_id)
      .maybeSingle();

    if (orderError || !order) {
      return new Response(
        JSON.stringify({ error: "Order not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Only the order's own buyer can trigger release (on delivery confirmation),
    // the server itself (service role, used by the scheduled auto-release job),
    // or an admin manually approving early release from the order-review queue.
    if (!isServiceRoleCall(req.headers.get("Authorization"))) {
      const callerId = getUserIdFromToken(req.headers.get("Authorization"));
      let isAdminCaller = false;
      if (callerId && callerId !== order.buyer_id) {
        const { data: callerUser } = await supabase
          .from("users")
          .select("role")
          .eq("id", callerId)
          .maybeSingle();
        isAdminCaller = callerUser?.role === "admin";
      }
      if (!callerId || (callerId !== order.buyer_id && !isAdminCaller)) {
        return new Response(
          JSON.stringify({ error: "Not authorized to release escrow for this order" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    if (!["confirmed", "auto_released"].includes(order.status)) {
      return new Response(
        JSON.stringify({ error: `Cannot release for order status: ${order.status}` }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (order.payment_released) {
      return new Response(
        JSON.stringify({ success: true, message: "Already released" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (order.has_dispute) {
      return new Response(
        JSON.stringify({ error: "Order has an active dispute. Release blocked until resolved." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // A vendor with an active post-payment dispute has their payouts held
    // so a buyer-favor refund can be funded from this hold instead of the
    // platform's own pocket — see dispute_bloc.dart createDispute.
    const { data: vendorRow } = await supabase
      .from("users")
      .select("payout_blocked, payout_blocked_reason")
      .eq("id", order.vendor_id)
      .maybeSingle();

    if (vendorRow?.payout_blocked) {
      return new Response(
        JSON.stringify({
          error: "payout_blocked",
          message: vendorRow.payout_blocked_reason || "Vendor has an active dispute. Payout blocked until resolved.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Atomically claim this release so two concurrent calls (e.g. the buyer
    // tapping confirm twice, or the cron job racing the buyer's app) can't
    // both pass the checks above and both trigger a Paystack transfer.
    const { data: claimed, error: claimError } = await supabase
      .from("orders")
      .update({ payment_released: true })
      .eq("id", order_id)
      .eq("payment_released", false)
      .in("status", ["confirmed", "auto_released"])
      .select("id");

    if (claimError) {
      return new Response(
        JSON.stringify({ error: "Failed to claim release" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!claimed || claimed.length === 0) {
      return new Response(
        JSON.stringify({ success: true, message: "Already released" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const vendor_id = order.vendor_id;

    // Use the payment transaction's payout if present, but DON'T require it —
    // fall back to computing from the order itself (courier = item subtotal only,
    // since the platform pays the courier; otherwise item + delivery). limit(1)
    // (not maybeSingle) so a duplicate payment tx can't throw. This makes release
    // resilient to a missing/duplicate payment row, which was leaving confirmed
    // orders stuck and unpaid.
    const { data: txRows } = await supabase
      .from("transactions")
      .select("vendor_payout, amount, platform_fee")
      .eq("order_id", order_id)
      .eq("status", "success")
      .eq("type", "payment")
      .limit(1);
    const tx = (txRows && txRows[0]) || null;

    const orderPayout = order.delivery_type === "courier"
      ? Number(order.total)
      : Number(order.total_with_delivery ?? order.total);
    const vendorPayout = (tx && (Number(tx.vendor_payout) || Number(tx.amount))) || orderPayout;
    const platformFee = tx ? (Number(tx.platform_fee) || 0) : 0;

    // Net any pending charges (e.g. failed-pickup courier fees) off this payout.
    // Settle whole charges that fit within the payout; larger ones wait for the
    // next one. The vendor only ever loses what they actually cost the platform.
    const { data: pendingCharges } = await supabase
      .from("vendor_charges")
      .select("id, amount")
      .eq("vendor_id", vendor_id)
      .eq("status", "pending");
    let chargeDeduct = 0;
    const chargesToSettle: string[] = [];
    for (const c of pendingCharges || []) {
      if (chargeDeduct + Number(c.amount) <= vendorPayout) {
        chargeDeduct += Number(c.amount);
        chargesToSettle.push(c.id);
      }
    }
    const netPayout = vendorPayout - chargeDeduct;
    const settleCharges = async () => {
      if (chargesToSettle.length > 0) {
        await supabase
          .from("vendor_charges")
          .update({ status: "settled", settled_at: new Date().toISOString() })
          .in("id", chargesToSettle);
      }
    };

    // Payout fully consumed by pending charges — nothing to credit.
    if (netPayout <= 0) {
      await settleCharges();
      await supabase.from("orders").update({ payment_released: true, status: "auto_released", payout_status: "paid" }).eq("id", order_id);
      await supabase.from("transactions").insert({
        order_id,
        buyer_id: order.buyer_id,
        vendor_id,
        store_id: order.store_id,
        amount: 0,
        platform_fee: platformFee,
        vendor_payout: 0,
        status: "success",
        type: "release",
        metadata: JSON.stringify({ reason: "offset_by_charges", charge_deduct: chargeDeduct, gross_payout: vendorPayout }),
      });
      return new Response(
        JSON.stringify({ success: true, amount_released: 0, message: "Payout fully offset by pending charges" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Credit the vendor's WALLET (provider-agnostic — no bank transfer here).
    // Synchronous and idempotent on reference, so there's no async "processing"
    // state or transfer webhook anymore. The vendor withdraws to bank later via
    // wallet-withdraw. No bank account is required just to RECEIVE the payout.
    const creditRef = `rel_${order_id}`;
    const { error: creditErr } = await supabase.rpc("wallet_credit", {
      p_user_id: vendor_id,
      p_amount: netPayout,
      p_type: "escrow_release",
      p_reference: creditRef,
      p_order_id: order_id,
      p_description: "Sale proceeds",
    });

    if (creditErr) {
      console.error("wallet_credit (escrow_release) error:", creditErr);
      // Couldn't credit — revert the claim so it can be retried.
      await supabase
        .from("orders")
        .update({ payment_released: false, payout_status: "failed" })
        .eq("id", order_id);
      return new Response(
        JSON.stringify({ error: "Failed to credit vendor wallet" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    await settleCharges();

    await supabase.from("transactions").insert({
      order_id,
      buyer_id: order.buyer_id,
      vendor_id,
      store_id: order.store_id,
      amount: netPayout,
      platform_fee: platformFee,
      vendor_payout: netPayout,
      status: "success",
      type: "release",
      metadata: JSON.stringify({ funding_target: "wallet", charge_deduct: chargeDeduct, gross_payout: vendorPayout }),
    });

    await supabase
      .from("orders")
      .update({ payment_released: true, status: "auto_released", payout_status: "paid" })
      .eq("id", order_id);

    await supabase.from("notifications").insert({
      user_id: vendor_id,
      title: "Payment received",
      body: `₦${netPayout.toLocaleString()} from a completed order was added to your wallet.`,
      type: "vendor_order",
      reference_id: order_id,
    });

    console.log(`Escrow released to wallet: order=${order_id}, vendor=${vendor_id}, amount=${netPayout} (gross=${vendorPayout}, charges=${chargeDeduct})`);

    return new Response(
      JSON.stringify({ success: true, amount_released: netPayout, credited_to: "wallet" }),
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
