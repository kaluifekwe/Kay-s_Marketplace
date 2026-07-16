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
const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";
const fromEmail = Deno.env.get("OTP_FROM_EMAIL") ?? "Kay's Market <onboarding@resend.dev>";

// Transactional email via Resend (same setup as the OTP/password emails).
async function sendEmail(to: string | null | undefined, subject: string, html: string) {
  if (!to || !resendKey) return;
  try {
    await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: fromEmail, to: [to], subject, html }),
    });
  } catch (e) {
    console.error("apply-status sendEmail failed:", e);
  }
}

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
  // cancelled / failed are handled explicitly (refund + charge) in the body.
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

  // Don't let a late courier event resurrect a CLOSED order. If the order was
  // already refunded or cancelled (e.g. an admin refund on a booked order), a
  // stray 'delivered'/'picked_up' webhook must NOT flip it back to shipped/
  // in_transit or open a fresh 24h escrow window (which could pay the vendor on
  // a refunded order). The delivery/tracking rows above still update so the
  // courier record stays accurate; we just leave the order state and the
  // buyer/vendor delivery prompts alone.
  const { data: ord } = await supabase
    .from("orders")
    .select("status")
    .eq("id", delivery.order_id)
    .maybeSingle();
  const orderClosed = !!ord && ["refunded", "refund_processing", "cancelled"].includes(ord.status);
  if (orderClosed) return;

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
  } else if ((status === "cancelled" || status === "failed") && !delivery.picked_up_at) {
    // Delivery didn't happen and the item was never collected — the buyer paid
    // but got nothing. 1) Charge the vendor the wasted courier fee the platform
    // already paid (netted off their next payout). 2) Auto-refund the buyer in
    // full to their wallet via process-refund (service-role, idempotent).
    // 3) Notify both parties. (Fixes the "cancelled = silent + stuck" gap.)
    await supabase.from("vendor_charges").upsert(
      {
        vendor_id: delivery.vendor_id,
        order_id: delivery.order_id,
        amount: delivery.shipbubble_fee ?? delivery.buyer_charged ?? 0,
        reason: status === "cancelled" ? "cancelled_pickup" : "failed_pickup",
        status: "pending",
      },
      { onConflict: "order_id,reason", ignoreDuplicates: true },
    );
    let refunded = false;
    try {
      const r = await fetch(`${supabaseUrl}/functions/v1/process-refund`, {
        method: "POST",
        headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          order_id: delivery.order_id,
          reason: `delivery_${status}_before_pickup`,
          refund_method: "wallet",
        }),
      });
      refunded = r.ok;
      if (!r.ok) console.error("apply-status auto-refund failed:", r.status, await r.text().catch(() => ""));
    } catch (e) {
      console.error("apply-status auto-refund error:", e);
    }
    await sendPush(
      delivery.buyer_id,
      "❌ Delivery Cancelled",
      refunded
        ? "The courier couldn't pick up your order, so you've been fully refunded to your wallet."
        : "There was a problem picking up your order. We're sorting your refund — contact support if it isn't resolved shortly.",
      { type: "delivery_update", status, order_id: delivery.order_id, delivery_id: delivery.id, screen: "order_tracking" },
    );
    await sendPush(
      delivery.vendor_id,
      "❌ Pickup Cancelled",
      "The courier couldn't collect this order, so the buyer was refunded. The courier fee will be netted off your next payout.",
      { type: "delivery_update", status, order_id: delivery.order_id, screen: "vendor_orders" },
    );
    return;
  } else if (status === "cancelled" || status === "failed") {
    // Cancelled/failed AFTER pickup — the item was already collected, so we don't
    // auto-refund. Move the order to 'delivery_failed' (no vendor auto-payout) so
    // the buyer's order screen shows a "Report Issue" path into the dispute/refund
    // flow (which refunds item-only), and notify both by push AND email.
    await supabase
      .from("orders")
      .update({ status: "delivery_failed", auto_release_at: null })
      .eq("id", delivery.order_id);

    const { data: parties } = await supabase
      .from("users")
      .select("id, email")
      .in("id", [delivery.buyer_id, delivery.vendor_id]);
    const emailOf = (uid: string) => (parties || []).find((u: any) => u.id === uid)?.email as string | undefined;

    await sendPush(
      delivery.buyer_id,
      "⚠️ Delivery Couldn't Be Completed",
      "The rider couldn't deliver your order. Open the order and tap Report Issue to get your refund.",
      { type: "delivery_update", status, order_id: delivery.order_id, delivery_id: delivery.id, screen: "order_tracking" },
    );
    await sendEmail(
      emailOf(delivery.buyer_id),
      "Your Kay's Market delivery couldn't be completed",
      "<p>Hi,</p><p>Unfortunately the rider couldn't complete the delivery of your order, and it is being returned. Please open the order in the Kay's Market app and tap <b>Report Issue</b> to request your refund.</p><p>— Kay's Market</p>",
    );
    await sendPush(
      delivery.vendor_id,
      "⚠️ Delivery Failed — Item Returning",
      "A delivery couldn't be completed and the item is being returned to you. The buyer's item payment will be refunded.",
      { type: "delivery_update", status, order_id: delivery.order_id, screen: "vendor_orders" },
    );
    await sendEmail(
      emailOf(delivery.vendor_id),
      "A Kay's Market delivery couldn't be completed",
      "<p>Hi,</p><p>A courier delivery for one of your orders couldn't be completed and the item is being returned to you. The buyer will be refunded the item value (the delivery fee is not refunded).</p><p>— Kay's Market</p>",
    );
    return;
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
