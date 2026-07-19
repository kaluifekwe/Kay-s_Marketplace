import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { applyDeliveryStatus, makeClient } from "../_shared/delivery/apply-status.ts";
import type { DeliveryStatus, WebhookEvent } from "../_shared/delivery/types.ts";
import { isScheduledCaller, refusalReason } from "../_shared/cron-auth.ts";

// Polling fallback for Shipbubble delivery status — the resilience twin of
// poll-terminal-deliveries. Shipbubble delivers status via its webhook, but a
// missed/undelivered webhook (their downtime, a network blip) would leave a
// cancelled pickup silently stuck with no refund — exactly the class of bug the
// Terminal poller guards against. Runs on pg_cron: it asks Shipbubble about all
// outstanding deliveries in one batched lookup and, where the status moved,
// applies it through the SAME shared applier the webhook uses (so "delivered"
// starts the 24h escrow clock and a cancel auto-refunds, identically).
// Idempotent: only applies on a real change, so re-running is safe.

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

  // Scheduler, or an operator holding the service key.
  if (!isScheduledCaller(req)) {
    console.error(`poll-shipbubble-deliveries: refused caller — ${refusalReason(req)}`);
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

  const active = (deliveries || []).filter((d) => d.provider_order_id);

  // Fetch every outstanding delivery in ONE call.
  //
  // This previously issued GET /shipping/labels/{order_id} per delivery, which
  // is not an endpoint Shipbubble has: it answered 400 on every attempt, so no
  // polled status update has ever been applied. Their documented lookup is
  // /shipping/labels/list/{comma-separated ids}, capped at 50 per request, and
  // it returns data.results rather than a single object.
  //
  // Batching also keeps the job inside the scheduler's timeout: one request per
  // 50 deliveries instead of one per delivery.
  const CHUNK = 50;
  for (let i = 0; i < active.length; i += CHUNK) {
    const batch = active.slice(i, i + CHUNK);
    const ids = batch.map((d) => d.provider_order_id).join(",");

    let results: any[] = [];
    try {
      const res = await fetch(`${SHIPBUBBLE_BASE}/shipping/labels/list/${encodeURIComponent(ids)}`, {
        headers: { Authorization: `Bearer ${SHIPBUBBLE_KEY}` },
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok || body?.status !== "success") {
        // One reason for the whole batch, recorded against each delivery in it
        // so a failure is visible per delivery rather than hidden in a total.
        const reason = `lookup ${res.status}: ${String(body?.message ?? "").slice(0, 80)}`;
        for (const d of batch) errors[d.id] = reason;
        console.error(`poll-shipbubble: batch of ${batch.length} failed — ${reason}`);
        continue;
      }
      results = Array.isArray(body?.data?.results) ? body.data.results : [];
    } catch (e: any) {
      for (const d of batch) errors[d.id] = e.message;
      continue;
    }

    const byOrderId = new Map<string, any>();
    for (const r of results) {
      if (r?.order_id) byOrderId.set(String(r.order_id), r);
    }

    for (const d of batch) {
      const r = byOrderId.get(String(d.provider_order_id));
      if (!r) {
        // Asked about it, got nothing back. Worth surfacing: it usually means
        // the stored order id is not one Shipbubble recognises, so this
        // delivery will never receive an update.
        errors[d.id] = "not returned by Shipbubble for the requested order id";
        continue;
      }
      const raw = String(r?.status ?? "").toLowerCase();
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
        courierName: r?.courier?.name ?? d.courier_name,
        courierPhone: r?.courier?.phone ?? d.courier_phone,
      };
      try {
        await applyDeliveryStatus(supabase, d, ev);
        updated.push(d.id);
      } catch (e: any) {
        errors[d.id] = e.message;
      }
    }
  }

  return json({ success: true, checked: active.length, updated, errors });
});
