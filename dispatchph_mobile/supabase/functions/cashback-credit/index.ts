import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

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

    // Kill switch. Google restricts apps that declare "financial features"
    // (Kay's Credit cashback = a rewards incentive) to ORGANIZATION accounts;
    // on a personal account the submission is rejected. Cashback is OFF by
    // default so the Play "no financial features" declaration is TRUE, not a
    // misrepresentation. Re-enable by setting CASHBACK_ENABLED=true once the
    // developer account is an organization. Returns success so callers
    // (auto-release-escrow / release-escrow) treat it as a no-op, never a
    // failure — with no cashback_amount, so no "cashback earned" push fires.
    if ((Deno.env.get("CASHBACK_ENABLED") ?? "false").toLowerCase() !== "true") {
      return new Response(
        JSON.stringify({ success: true, disabled: true, cashback_amount: 0 }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    const { order_id, buyer_id } = await req.json();

    if (!order_id || !buyer_id) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: order_id, buyer_id" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Either the buyer themselves (manual delivery confirmation), or the
    // server itself (service role, used by the auto-release cron job).
    if (!isServiceRoleCall(req.headers.get("Authorization"))) {
      if (!callerId || callerId !== buyer_id) {
        return new Response(
          JSON.stringify({ error: "Authenticated user does not match buyer_id" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Get order details
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("id, buyer_id, total, status")
      .eq("id", order_id)
      .maybeSingle();

    if (orderError || !order) {
      return new Response(
        JSON.stringify({ error: "Order not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (order.buyer_id !== buyer_id) {
      return new Response(
        JSON.stringify({ error: "Order does not belong to this buyer" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Cashback applies whether the order completed via the buyer manually
    // confirming delivery, or via auto-release (timer/cron) — either way
    // the sale completed successfully. Previously only "confirmed" was
    // accepted, so any auto-released order never got cashback at all.
    if (!["confirmed", "auto_released"].includes(order.status)) {
      return new Response(
        JSON.stringify({ error: `Cannot add cashback for order status: ${order.status}` }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Check if cashback already given for this order
    const { data: existingCashback } = await supabase
      .from("credit_transactions")
      .select("id")
      .eq("order_id", order_id)
      .eq("type", "cashback")
      .maybeSingle();

    if (existingCashback) {
      return new Response(
        JSON.stringify({ success: true, message: "Cashback already awarded" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Fixed-naira cashback tiers (not a percentage) — kept simple and
    // capped low since this is funded entirely out of platform margin on
    // a zero-revenue startup; cost scales loosely with order size without
    // ever paying out more than a fixed amount per order.
    let cashbackAmount: number;
    if (order.total < 5000) {
      cashbackAmount = 50;
    } else if (order.total < 15000) {
      cashbackAmount = 100;
    } else {
      cashbackAmount = 150;
    }
    const description = `₦${cashbackAmount} cashback reward`;

    const expiresAt = new Date();
    expiresAt.setDate(expiresAt.getDate() + 90);

    // Add credit to buyer
    await supabase.rpc("increment_kays_credit", {
      p_user_id: buyer_id,
      p_amount: cashbackAmount,
    }).then(async (res) => {
      // If RPC doesn't exist, fall back to direct update
      if (res.error) {
        const { data: user } = await supabase
          .from("users")
          .select("kays_credit")
          .eq("id", buyer_id)
          .maybeSingle();
        const currentCredit = user?.kays_credit || 0;
        await supabase
          .from("users")
          .update({ kays_credit: currentCredit + cashbackAmount })
          .eq("id", buyer_id);
      }
    });

    // Log credit transaction
    await supabase.from("credit_transactions").insert({
      buyer_id,
      amount: cashbackAmount,
      type: "cashback",
      order_id,
      description,
      expires_at: expiresAt.toISOString(),
    });

    console.log(`Cashback awarded: buyer=${buyer_id}, order=${order_id}, amount=${cashbackAmount}`);

    return new Response(
      JSON.stringify({
        success: true,
        cashback_amount: cashbackAmount,
        description,
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
