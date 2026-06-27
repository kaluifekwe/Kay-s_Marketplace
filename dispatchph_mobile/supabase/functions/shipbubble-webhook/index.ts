import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Receives delivery status updates from Shipbubble and reflects them onto the
// deliveries / delivery_tracking / orders tables, plus push notifications.
//
// IMPORTANT (escrow timing): for courier orders the 24h confirm/auto-release
// window starts at the REAL delivered event — we set orders.auto_release_at =
// delivered + 24h here. We deliberately do NOT write dispute_deadline; the
// single source of truth for the window is auto_release_at (see
// dispute_bloc.dart checkDisputeEligibility and auto-release-escrow cron).

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const shipbubbleKey = Deno.env.get("SHIPBUBBLE_API_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const STATUS_MAP: Record<string, string> = {
  pending: "pending",
  confirmed: "confirmed",
  picked_up: "picked_up",
  "picked-up": "picked_up",
  in_transit: "in_transit",
  intransit: "in_transit",
  completed: "delivered",
  delivered: "delivered",
  failed: "failed",
  cancelled: "cancelled",
  canceled: "cancelled",
};

function statusDescription(status: string): string {
  const d: Record<string, string> = {
    pending: "Courier booking received",
    confirmed: "Courier confirmed your delivery",
    picked_up: "Item picked up from vendor",
    in_transit: "Item on the way to you",
    delivered: "Item delivered successfully",
    failed: "Delivery attempt failed",
    cancelled: "Delivery cancelled",
  };
  return d[status] ?? status;
}

async function sendPush(userId: string | null | undefined, title: string, body: string, data: Record<string, unknown>) {
  if (!userId) return;
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
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Verify it's really Shipbubble. They sign with the account API key in a
    // header; reject anything that doesn't present it. (Adjust header name to
    // match your Shipbubble webhook settings if different.)
    const signature =
      req.headers.get("x-shipbubble-signature") || req.headers.get("shipbubble-signature") || "";
    if (!signature || signature !== shipbubbleKey) {
      return new Response(JSON.stringify({ error: "Forbidden" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const payload = await req.json();
    const data = payload.data ?? payload;

    const shipbubbleOrderId = data.order_id ?? data.shipbubble_order_id;
    const rawStatus = String(data.status ?? "").toLowerCase();
    const courier = data.courier ?? {};
    const kaysStatus = STATUS_MAP[rawStatus] ?? rawStatus;

    if (!shipbubbleOrderId) {
      return new Response(JSON.stringify({ error: "Missing order_id" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: delivery } = await supabase
      .from("deliveries")
      .select("*")
      .eq("shipbubble_order_id", shipbubbleOrderId)
      .maybeSingle();

    if (!delivery) {
      return new Response(JSON.stringify({ error: "Delivery not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const nowIso = new Date().toISOString();

    await supabase
      .from("deliveries")
      .update({
        status: kaysStatus,
        courier_name: courier.name ?? delivery.courier_name,
        courier_phone: courier.phone ?? delivery.courier_phone,
        picked_up_at: kaysStatus === "picked_up" ? nowIso : delivery.picked_up_at,
        delivered_at: kaysStatus === "delivered" ? nowIso : delivery.delivered_at,
      })
      .eq("id", delivery.id);

    await supabase.from("delivery_tracking").insert({
      delivery_id: delivery.id,
      status: kaysStatus,
      description: statusDescription(kaysStatus),
      location: data.location ?? null,
      timestamp: nowIso,
    });

    // Reflect onto the order. On delivery, start the 24h escrow window from
    // the real delivered event (courier orders only). The order moves to
    // 'shipped' so the existing buyer "Confirm & Release" / "Request Refund"
    // UI (gated on status=='shipped') and the auto-release cron both apply.
    if (kaysStatus === "delivered") {
      await supabase
        .from("orders")
        .update({
          status: "shipped",
          shipped_at: delivery.picked_up_at ?? nowIso,
          delivered_at: nowIso,
          auto_release_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
        })
        .eq("id", delivery.order_id);
    } else if (kaysStatus === "picked_up" || kaysStatus === "in_transit") {
      await supabase.from("orders").update({ status: "in_transit" }).eq("id", delivery.order_id);
    }

    // Push notifications per status.
    const notif: Record<string, { buyer?: [string, string]; vendor?: [string, string] }> = {
      confirmed: {
        buyer: ["✅ Courier Confirmed!", `${delivery.courier_name ?? "Your courier"} confirmed your delivery.`],
        vendor: ["✅ Courier Confirmed!", "Courier is on the way to pick up your item."],
      },
      picked_up: {
        buyer: ["📦 Order Picked Up!", "Your order is on its way! Track delivery in the app."],
        vendor: ["✅ Item Picked Up!", "Courier has picked up your item successfully."],
      },
      delivered: {
        buyer: ["🎉 Order Arrived!", "Your order has been delivered! Please confirm receipt within 24h."],
      },
      failed: {
        buyer: ["⚠️ Delivery Issue", "There was an issue with your delivery. Contact support."],
        vendor: ["⚠️ Delivery Failed", "Delivery was unsuccessful. Please contact Kay's support."],
      },
    };

    const n = notif[kaysStatus];
    if (n?.buyer) {
      await sendPush(delivery.buyer_id, n.buyer[0], n.buyer[1], {
        type: "delivery_update",
        status: kaysStatus,
        order_id: delivery.order_id,
        delivery_id: delivery.id,
        screen: "order_tracking",
      });
    }
    if (n?.vendor) {
      await sendPush(delivery.vendor_id, n.vendor[0], n.vendor[1], {
        type: "delivery_update",
        status: kaysStatus,
        order_id: delivery.order_id,
        screen: "vendor_orders",
      });
    }

    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error: any) {
    console.error("shipbubble-webhook error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
