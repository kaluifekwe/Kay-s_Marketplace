import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getNumber } from "../_shared/settings.ts";
import { isScheduledCaller, refusalReason } from "../_shared/cron-auth.ts";

// Scheduled (pg_cron, see pickup_sla.sql): courier orders the vendor hasn't
// booked. Reminds the vendor REMINDER_BEFORE_HOURS before the deadline, then at
// the deadline auto-cancels + refunds the buyer (via process-refund, which is
// idempotent). No courier is booked until the vendor acts, so an expired order
// has cost nothing and the buyer gets a clean full refund.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Auto-cancel refunds go to Kay's Credit (instant). Change to "card"/"bank" to
// refund the original method instead.
const REFUND_METHOD = Deno.env.get("PICKUP_REFUND_METHOD") ?? "credit";
// Tunable in the admin console (app_settings); literals stay as fallbacks.
const REMINDER_BEFORE_HOURS_DEFAULT = 12;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

async function sendPush(userId: string, title: string, body: string, data: Record<string, unknown>) {
  try {
    await fetch(`${supabaseUrl}/functions/v1/send-push`, {
      method: "POST",
      headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ user_id: userId, title, body, data }),
    });
  } catch (e) {
    console.error("sendPush failed:", e);
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  // Scheduler, or an operator holding the service key.
  if (!isScheduledCaller(req)) {
    console.error(`expire-unbooked-pickups: refused caller — ${refusalReason(req)}`);
    return json({ error: "Forbidden" }, 403);
  }

  const supabase = createClient(supabaseUrl, supabaseServiceKey);
  const now = Date.now();
  const reminded: string[] = [];
  const expired: string[] = [];

  try {
    // Courier orders awaiting the vendor's pickup request.
    const { data: orders } = await supabase
      .from("orders")
      .select("id, buyer_id, vendor_id, pickup_deadline, pickup_reminded")
      .eq("status", "paid")
      .eq("delivery_type", "courier")
      .eq("has_shipbubble_delivery", false)
      .not("pickup_deadline", "is", null);

    for (const o of orders || []) {
      const deadline = new Date(o.pickup_deadline).getTime();
      const remindAt = deadline -
        (await getNumber("pickup_reminder_before_hours", "PICKUP_REMINDER_BEFORE_HOURS", REMINDER_BEFORE_HOURS_DEFAULT)) * 60 * 60 * 1000;

      if (now >= deadline) {
        // Deadline passed — refund the buyer (idempotent) and notify both sides.
        const res = await fetch(`${supabaseUrl}/functions/v1/process-refund`, {
          method: "POST",
          headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({ order_id: o.id, refund_method: REFUND_METHOD, reason: "pickup_expired" }),
        });
        if (!res.ok) {
          console.error(`Refund failed for expired pickup ${o.id}:`, await res.text());
          continue;
        }
        expired.push(o.id);
        await sendPush(
          o.buyer_id,
          "Order cancelled & refunded",
          "The vendor didn't arrange pickup in time, so your order was cancelled and you've been refunded.",
          { type: "order_cancelled", order_id: o.id, screen: "orders" },
        );
        await sendPush(
          o.vendor_id,
          "Order auto-cancelled",
          "You didn't request a courier pickup in time, so the order was cancelled and the buyer refunded.",
          { type: "order_cancelled", order_id: o.id, screen: "vendor_orders" },
        );
      } else if (now >= remindAt && !o.pickup_reminded) {
        await sendPush(
          o.vendor_id,
          "⏰ Request pickup soon",
          "Package your order and tap Request Pickup, or it will be auto-cancelled and the buyer refunded.",
          { type: "pickup_reminder", order_id: o.id, screen: "vendor_orders" },
        );
        await supabase.from("orders").update({ pickup_reminded: true }).eq("id", o.id);
        reminded.push(o.id);
      }
    }

    return json({ success: true, reminded, expired });
  } catch (error: any) {
    console.error("expire-unbooked-pickups error:", error);
    return json({ error: error.message }, 500);
  }
});
