// Shared webhook logic: given a normalized WebhookEvent from any provider,
// reflect it onto deliveries / delivery_tracking / orders and push notifications.
// Every *-webhook function does provider-specific auth + parseWebhook, then calls
// applyDeliveryStatus — so status handling lives in exactly one place.
//
// IMPORTANT (escrow timing): for courier orders the 24h confirm/auto-release
// window starts at the REAL delivered event — orders.auto_release_at =
// delivered + 24h. We deliberately do NOT write dispute_deadline; the single
// source of truth for the window is auto_release_at.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { DeliveryStatus, WebhookEvent } from "./types.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

export function makeClient() {
  return createClient(supabaseUrl, supabaseServiceKey);
}

// Find the delivery by its provider order id; fall back to the legacy
// shipbubble_order_id column for rows booked before the multi-provider refactor.
export async function findDelivery(supabase: any, providerOrderId: string) {
  let { data } = await supabase.from("deliveries").select("*").eq("provider_order_id", providerOrderId).maybeSingle();
  if (!data) {
    ({ data } = await supabase.from("deliveries").select("*").eq("shipbubble_order_id", providerOrderId).maybeSingle());
  }
  return data;
}

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

const NOTIF: Record<string, { buyer?: [string, string]; vendor?: [string, string] }> = {
  confirmed: {
    buyer: ["✅ Courier Confirmed!", "Your courier confirmed the delivery."],
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

export async function applyDeliveryStatus(supabase: any, delivery: any, ev: WebhookEvent, location?: string | null) {
  const status: DeliveryStatus = ev.status;
  const nowIso = new Date().toISOString();

  await supabase
    .from("deliveries")
    .update({
      status,
      courier_name: ev.courierName ?? delivery.courier_name,
      courier_phone: ev.courierPhone ?? delivery.courier_phone,
      picked_up_at: status === "picked_up" ? nowIso : delivery.picked_up_at,
      delivered_at: status === "delivered" ? nowIso : delivery.delivered_at,
    })
    .eq("id", delivery.id);

  await supabase.from("delivery_tracking").insert({
    delivery_id: delivery.id,
    status,
    description: statusDescription(status),
    location: location ?? null,
    timestamp: nowIso,
  });

  // Failed pickup: courier dispatched but the vendor had nothing ready (failed
  // BEFORE pickup). The platform already paid the courier fee, so record it as a
  // pending charge against the vendor — release-escrow nets it off a future
  // payout. Idempotent via the unique (order_id, reason) index.
  if (status === "failed" && !delivery.picked_up_at) {
    await supabase.from("vendor_charges").upsert(
      {
        vendor_id: delivery.vendor_id,
        order_id: delivery.order_id,
        amount: delivery.shipbubble_fee ?? delivery.buyer_charged ?? 0,
        reason: "failed_pickup",
        status: "pending",
      },
      { onConflict: "order_id,reason", ignoreDuplicates: true },
    );
  }

  // Reflect onto the order. On delivery, start the 24h escrow window from the
  // real delivered event (courier orders only). The order moves to 'shipped'
  // so the buyer "Confirm & Release" / "Request Refund" UI and the auto-release
  // cron (both gated on status) apply.
  if (status === "delivered") {
    await supabase
      .from("orders")
      .update({
        status: "shipped",
        shipped_at: delivery.picked_up_at ?? nowIso,
        delivered_at: nowIso,
        auto_release_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      })
      .eq("id", delivery.order_id);
  } else if (status === "picked_up" || status === "in_transit") {
    await supabase.from("orders").update({ status: "in_transit" }).eq("id", delivery.order_id);
  }

  const n = NOTIF[status];
  if (n?.buyer) {
    await sendPush(delivery.buyer_id, n.buyer[0], n.buyer[1], {
      type: "delivery_update",
      status,
      order_id: delivery.order_id,
      delivery_id: delivery.id,
      screen: "order_tracking",
    });
  }
  if (n?.vendor) {
    await sendPush(delivery.vendor_id, n.vendor[0], n.vendor[1], {
      type: "delivery_update",
      status,
      order_id: delivery.order_id,
      screen: "vendor_orders",
    });
  }
}
