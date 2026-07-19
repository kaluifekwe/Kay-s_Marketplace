import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { applyDeliveryStatus, makeClient } from "../_shared/delivery/apply-status.ts";
import type { DeliveryStatus, WebhookEvent } from "../_shared/delivery/types.ts";
import { isScheduledCaller, refusalReason } from "../_shared/cron-auth.ts";

// Polling fallback for Terminal Africa delivery status, for accounts where the
// Terminal webhook can't be registered. Runs on pg_cron: for each active Terminal
// delivery it GETs the shipment from Terminal and, if the status moved, applies
// it through the SAME shared applier the webhooks use (so "delivered" starts the
// 24h escrow clock exactly the same way). Idempotent: only applies on a real
// change, so re-running is safe.

const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TERMINAL_KEY = Deno.env.get("TERMINAL_API_KEY") ?? "";
const TERMINAL_BASE = Deno.env.get("TERMINAL_BASE_URL") ?? "https://api.terminal.africa/v1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

// Terminal shipment.status -> our DeliveryStatus. Early/unknown states (e.g.
// "draft") map to nothing so we never fabricate a transition from a poll.
const STATUS_MAP: Record<string, DeliveryStatus> = {
  "pending": "pending",
  "pickup-pending": "pending",
  "confirmed": "confirmed",
  "shipment.confirmed": "confirmed",
  "picked-up": "picked_up",
  "in-transit": "in_transit",
  "shipment.in-transit": "in_transit",
  "delivered": "delivered",
  "shipment.delivered": "delivered",
  "cancelled": "cancelled",
  "shipment.cancelled": "cancelled",
  // Terminal uses "rejected" when a pickup is refused (e.g. vendor unavailable) —
  // treat it as a cancellation so the buyer is refunded + everyone notified.
  "rejected": "cancelled",
  "shipment.rejected": "cancelled",
  "failed": "failed",
  "shipment.failed": "failed",
  "returned": "failed",
  "shipment.returned": "failed",
  "pickup-failed": "failed",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  // Scheduler, or an operator holding the service key.
  if (!isScheduledCaller(req)) {
    console.error(`poll-terminal-deliveries: refused caller — ${refusalReason(req)}`);
    return json({ error: "Forbidden" }, 403);
  }
  if (!TERMINAL_KEY) return json({ error: "no_terminal_key" }, 400);

  const supabase = makeClient();
  const { data: deliveries } = await supabase
    .from("deliveries")
    .select("*")
    .eq("provider", "terminal")
    .not("status", "in", "(delivered,cancelled,failed)");

  const updated: string[] = [];
  const errors: Record<string, string> = {};

  for (const d of deliveries || []) {
    if (!d.provider_order_id) continue;
    try {
      const res = await fetch(`${TERMINAL_BASE}/shipments/${d.provider_order_id}`, {
        headers: { Authorization: `Bearer ${TERMINAL_KEY}` },
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) {
        errors[d.id] = `lookup ${res.status}: ${String(body?.message ?? "").slice(0, 80)}`;
        continue;
      }
      const raw = String(body?.data?.status ?? "").toLowerCase();
      const mapped = STATUS_MAP[raw];
      if (!mapped) {
        // Surface unknown statuses instead of silently skipping (this is exactly
        // how the "rejected" cancel went undetected before).
        if (raw && raw !== "draft") console.warn(`poll-terminal: unmapped Terminal status "${raw}" for delivery ${d.id}`);
        continue;
      }
      if (mapped === d.status) continue; // no change since last poll

      const ev: WebhookEvent = {
        providerOrderId: d.provider_order_id,
        status: mapped,
        courierName: body?.data?.carrier?.name ?? d.courier_name,
        courierPhone: body?.data?.carrier?.phone ?? d.courier_phone,
      };
      await applyDeliveryStatus(supabase, d, ev);
      updated.push(d.id);
    } catch (e: any) {
      errors[d.id] = e.message;
    }
  }

  return json({ success: true, checked: deliveries?.length ?? 0, updated, errors });
});
