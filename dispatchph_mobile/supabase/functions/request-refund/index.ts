import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Buyer asks for a refund on an order. This does NOT move money — it queues the
// request for administrator approval (see admin-decide-refund).
//
// Refunds are paid out to the buyer's own bank account, so a VERIFIED account
// must be on file before a request can be raised; there is nowhere else for the
// money to go. The app should prompt the buyer to add one when this returns
// `no_bank_account`.
//
// Automated refunds — delivery failed before pickup, expired vendor pickup,
// dispute resolutions — deliberately do not come through here. They have their
// own rules and stay immediate.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

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
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    if (!callerId) return json({ error: "Unauthorized" }, 401);

    const { order_id, reason } = await req.json();
    if (!order_id) return json({ error: "Missing order_id" }, 400);

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: order } = await supabase
      .from("orders")
      .select("id, buyer_id, status, total, total_with_delivery, has_shipbubble_delivery, delivery_type, paid_at, created_at")
      .eq("id", order_id)
      .maybeSingle();
    if (!order) return json({ error: "Order not found" }, 404);
    if (order.buyer_id !== callerId) return json({ error: "Forbidden" }, 403);

    // Two paths may raise a refund request here:
    //  1. Plain pre-rider cancel — a 'paid' order with no courier booked yet.
    //  2. Stuck safety net — a booked courier order that never arrived and has
    //     stalled past the grace period. A courier can reject a pickup and never
    //     report it back (Terminal did exactly this), leaving the order frozen at
    //     'paid'/'in_transit' with the buyer unable to recover their money any
    //     other way. This does NOT move money — it queues a request an admin
    //     reviews, so a genuinely in-flight delivery isn't refunded by mistake.
    const STALL_HOURS = 3;
    const riderBooked = order.delivery_type === "courier" && order.has_shipbubble_delivery === true;
    const placed = order.paid_at ?? order.created_at;
    const hoursSince = placed ? (Date.now() - new Date(placed).getTime()) / 3_600_000 : Infinity;
    const stuckStates = ["paid", "in_transit"];

    const plainCancel = order.status === "paid" && !riderBooked;
    const stuckRequest = riderBooked && stuckStates.includes(order.status) && hoursSince >= STALL_HOURS;

    if (!plainCancel && !stuckRequest) {
      if (riderBooked && stuckStates.includes(order.status)) {
        const wait = Math.max(1, Math.ceil(STALL_HOURS - hoursSince));
        return json({
          error: "too_soon",
          message: `Your order may still be on the way. If it hasn't arrived, you can request a refund in about ${wait} hour(s).`,
        }, 409);
      }
      return json({ error: "not_refundable", message: "This order can no longer be refunded." }, 400);
    }

    // A bank account is required only for a plain cancel (paid to the buyer's
    // bank). A stuck safety-net request must NOT be blocked by a missing bank —
    // the buyer got nothing, and admin review (process-refund) falls back to the
    // wallet when there's no verified bank on file.
    if (plainCancel) {
      const { data: bank } = await supabase
        .from("buyer_bank_accounts")
        .select("is_verified, bank_code, account_number")
        .eq("buyer_id", callerId)
        .maybeSingle();
      if (!bank?.is_verified || !bank.bank_code || !bank.account_number) {
        return json({
          error: "no_bank_account",
          message: "Add and verify your bank account first — that's where the refund is paid.",
        }, 400);
      }
    }

    // Idempotent: a second tap returns the existing pending request rather than
    // queueing a duplicate (also enforced by a partial unique index).
    const { data: existing } = await supabase
      .from("refund_requests")
      .select("id, status, created_at")
      .eq("order_id", order_id)
      .eq("status", "pending")
      .maybeSingle();
    if (existing) {
      return json({ success: true, already_requested: true, request: existing });
    }

    const amount = Number(order.total_with_delivery ?? order.total) || 0;
    const { data: created, error: insErr } = await supabase
      .from("refund_requests")
      .insert({
        order_id,
        buyer_id: callerId,
        amount,
        reason: (reason && String(reason).trim()) ||
          (stuckRequest ? "Order stuck — rider booked but never delivered" : "Buyer requested a refund"),
        status: "pending",
      })
      .select("id, status, amount, created_at")
      .single();
    if (insErr || !created) {
      console.error("request-refund insert error:", insErr);
      return json({ error: "Could not submit your refund request. Please try again." }, 500);
    }

    // Flag the order so it stops looking payable/shippable while under review.
    // process-refund accepts 'refund_requested', so approval can proceed from here.
    await supabase.from("orders").update({ status: "refund_requested" }).eq("id", order_id);

    // Let the admins know there is something to review.
    try {
      const { data: admins } = await supabase.from("users").select("id").eq("role", "admin");
      for (const a of admins ?? []) {
        await supabase.from("notifications").insert({
          user_id: (a as any).id,
          title: "Refund request",
          body: `A buyer requested a ₦${amount.toLocaleString()} refund. Review it in the admin console.`,
          type: "general",
          reference_id: order_id,
        });
      }
    } catch (_) { /* best-effort */ }

    return json({ success: true, request: created });
  } catch (error: any) {
    console.error("request-refund error:", error);
    return json({ error: error.message }, 500);
  }
});
