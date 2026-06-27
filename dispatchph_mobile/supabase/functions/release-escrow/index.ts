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
      .select("id, buyer_id, vendor_id, store_id, status, payment_released, total, has_dispute")
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

    const { data: tx } = await supabase
      .from("transactions")
      .select("*")
      .eq("order_id", order_id)
      .eq("status", "success")
      .eq("type", "payment")
      .maybeSingle();

    if (!tx) {
      // Release the claim so this can be retried once a payment exists.
      await supabase.from("orders").update({ payment_released: false }).eq("id", order_id);
      return new Response(
        JSON.stringify({ error: "No successful payment found for this order" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const vendorPayout = tx.vendor_payout || tx.amount;

    const { data: bankAccount } = await supabase
      .from("vendor_bank_accounts")
      .select("*")
      .eq("user_id", vendor_id)
      .eq("is_verified", true)
      .maybeSingle();

    if (!bankAccount || !bankAccount.paystack_recipient_code) {
      console.error(`No verified bank account for vendor ${vendor_id}`);
      await supabase
        .from("orders")
        .update({ payment_released: true, status: "auto_released" })
        .eq("id", order_id);

      await supabase.from("transactions").insert({
        order_id,
        buyer_id: order.buyer_id,
        vendor_id,
        store_id: order.store_id,
        amount: vendorPayout,
        status: "pending",
        type: "release",
        metadata: JSON.stringify({ reason: "vendor_no_bank_account" }),
      });

      return new Response(
        JSON.stringify({ success: true, message: "Released but vendor has no bank account" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
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
        amount: Math.round(vendorPayout * 100),
        recipient: bankAccount.paystack_recipient_code,
        reason: `Order ${order_id.substring(0, 8)} payment release`,
        reference: `rel_${order_id}`,
      }),
    });

    const transferData = await transferResponse.json();

    if (!transferData.status) {
      console.error("Paystack transfer error:", transferData);
      // Release the claim so this can be retried — the transfer never went out.
      await supabase.from("orders").update({ payment_released: false }).eq("id", order_id);
      return new Response(
        JSON.stringify({ error: transferData.message || "Transfer failed" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    await supabase.from("transactions").insert({
      order_id,
      buyer_id: order.buyer_id,
      vendor_id,
      store_id: order.store_id,
      amount: vendorPayout,
      platform_fee: tx.platform_fee,
      vendor_payout: vendorPayout,
      status: "success",
      type: "release",
      paystack_reference: transferData.data.reference,
      metadata: JSON.stringify({ transfer_code: transferData.data.transfer_code }),
    });

    await supabase
      .from("orders")
      .update({
        payment_released: true,
        status: "auto_released",
      })
      .eq("id", order_id);

    console.log(`Escrow released: order=${order_id}, vendor=${vendor_id}, amount=${vendorPayout}`);

    return new Response(
      JSON.stringify({
        success: true,
        amount_released: vendorPayout,
        transfer_reference: transferData.data.reference,
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
