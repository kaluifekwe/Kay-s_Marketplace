import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { applyDeliveryStatus, makeClient } from "../_shared/delivery/apply-status.ts";
import type { DeliveryStatus, WebhookEvent } from "../_shared/delivery/types.ts";

// Polling fallback for Shipbubble delivery status — the resilience twin of
// poll-terminal-deliveries. Shipbubble delivers status via its webhook, but a
// missed/undelivered webhook (their downtime, a network blip) would leave a
// cancelled pickup silently stuck with no refund — exactly the class of bug the
// Terminal poller guards against. Runs on pg_cron: for each active Shipbubble
// delivery it GETs the label from Shipbubble and, if the status moved, applies
// it through the SAME shared applier the webhook uses (so "delivered" starts the
// 24h escrow clock and a cancel auto-refunds, identically). Idempotent: only
// applies on a real change, so re-running is safe.

const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SHIPBUBBLE_KEY = Deno.env.get("SHIPBUBBLE_API_KEY") ?? "";
const SHIPBUBBLE_BASE = "https://api.shipbubble.com/v1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

// Shipbubble label.status -> our DeliveryStatus. Kept in lockstep with the map
// in shipbubble.ts parseWebhook. Early/unknown states map to nothing so we never
// fabricate a transition from a poll (e.g. don't advance an order on "rejected").
const STATUS_MAP: Record<string, DeliveryStatus> = {
  pending: "pending",
  confirmed: "confirmed",
  picked_up: "picked_up",
  in_transit: "in_transit",
  delivered: "delivered",
  completed: "delivered",
  failed: "failed",
  cancelled: "cancelled",
  rejected: "cancelled",
  returned: "failed",
  delivery_failed: "failed",
  pickup_failed: "failed",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  // Service-role only (pg_cron / internal).
  if ((req.headers.get("Authorization") || "").replace("Bearer ", "") !== supabaseServiceKey) {
    return json({ error: "Forbidden" }, 403);
  }
  if (!SHIPBUBBLE_KEY) return json({ error: "no_shipbubble_key" }, 400);

  const supabase = makeClient();
  const { data: deliveries } = await supabase
    .from("deliveries")
    .select("*")
    .eq("provider", "shipbubble")
    .not("status", "in", "(delivered,cancelled,failed)");

  const updated: string[] = [];
  const errors: Record<string, string> = {};

  for (const d of deliveries || []) {
    if (!d.provider_order_id) continue;
    try {
      const res = await fetch(`${SHIPBUBBLE_BASE}/shipping/labels/${d.provider_order_id}`, {
        headers: { Authorization: `Bearer ${SHIPBUBBLE_KEY}` },
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok || body?.status !== "success") {
        errors[d.id] = `lookup ${res.status}: ${String(body?.message ?? "").slice(0, 80)}`;
        continue;
      }
      const raw = String(body?.data?.status ?? "").toLowerCase();
      const mapped = STATUS_MAP[raw];
      if (!mapped) {
        // Surface unknown statuses instead of silently skipping (this is exactly
        // how the "rejected" cancel went undetected before).
        if (raw) console.warn(`poll-shipbubble: unmapped Shipbubble status "${raw}" for delivery ${d.id}`);
        continue;
      }
      if (mapped === d.status) continue; // no change since last poll

      const ev: WebhookEvent = {
        providerOrderId: d.provider_order_id,
        status: mapped,
        courierName: body?.data?.courier?.name ?? d.courier_name,
        courierPhone: body?.data?.courier?.phone ?? d.courier_phone,
      };
      await applyDeliveryStatus(supabase, d, ev);
      updated.push(d.id);
    } catch (e: any) {
      errors[d.id] = e.message;
    }
  }

  return json({ success: true, checked: deliveries?.length ?? 0, updated, errors });
});
