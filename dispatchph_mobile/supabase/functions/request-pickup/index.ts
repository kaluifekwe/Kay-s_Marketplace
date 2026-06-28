import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { quoteAll } from "../_shared/delivery/orchestrate.ts";

// Vendor-triggered courier booking ("Request Pickup"). Courier orders are NOT
// booked at payment anymore — the vendor packages the item, taps Ready, and we
// re-quote fresh and book then, so the rider isn't summoned before the item
// exists. The buyer already paid the delivery fee into escrow at checkout; the
// platform absorbs the (small, stable) re-quote variance and never re-charges
// the buyer.
//
// Safety: vendor-only authZ on their own order; idempotent (one active delivery
// per order, enforced by a partial unique index + a check-first guard); atomic
// (either a delivery is created or nothing changes — booking is delegated to
// book-delivery which gates on the courier wallet).

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

// Block absurd re-quote spikes (platform absorbs normal drift, not 50%+ jumps).
const PRICE_SPIKE_TOLERANCE = 1.5;

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

  try {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    if (!callerId) return json({ error: "Unauthorized" }, 401);

    const { order_id } = await req.json();
    if (!order_id) return json({ error: "Missing order_id" }, 400);

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: order } = await supabase.from("orders").select("*").eq("id", order_id).maybeSingle();
    if (!order) return json({ error: "Order not found" }, 404);

    // AuthZ: only the order's own vendor may request its pickup.
    if (order.vendor_id !== callerId) return json({ error: "Forbidden" }, 403);
    if (order.delivery_type !== "courier") return json({ error: "not_a_courier_order" }, 400);

    // Idempotency: if there is already an active delivery for this order, return
    // it instead of booking again.
    const { data: existing } = await supabase
      .from("deliveries")
      .select("id, status")
      .eq("order_id", order_id)
      .not("status", "in", "(cancelled,failed)")
      .maybeSingle();
    if (existing) {
      return json({ booked: true, already_booked: true, delivery_id: existing.id });
    }

    if (order.status !== "paid") return json({ error: "order_not_payable_state", status: order.status }, 400);
    if (!order.delivery_quote_id) return json({ error: "no_original_quote" }, 400);

    // The original checkout quote holds the addresses + items to re-quote with.
    const { data: origQuote } = await supabase
      .from("delivery_quotes")
      .select("*")
      .eq("id", order.delivery_quote_id)
      .maybeSingle();
    const bundle = origQuote?.available_couriers || {};
    if (!origQuote || !bundle.sender || !bundle.receiver || !Array.isArray(bundle.items)) {
      return json({ error: "original_quote_unusable" }, 400);
    }

    // Re-quote fresh — the 15-min checkout quote is long gone.
    const { couriers, providerData, reason } = await quoteAll({
      sender: bundle.sender,
      receiver: bundle.receiver,
      items: bundle.items,
    });
    if (couriers.length === 0) {
      // No courier covers the route right now — order stays paid, vendor retries.
      return json({ booked: false, reason: `courier_unavailable: ${reason}` });
    }

    // Prefer the courier the buyer chose; else the cheapest equivalent.
    const paidFee = Number(order.delivery_fee) || 0;
    const chosen =
      couriers.find((c) => c.provider === order.selected_provider && c.name === order.selected_courier_name) ||
      couriers[0];

    // Guard against absurd price spikes; platform absorbs normal drift.
    if (paidFee > 0 && chosen.fee > paidFee * PRICE_SPIKE_TOLERANCE) {
      return json({
        booked: false,
        reason: "price_spike",
        message: `Courier price rose sharply (₦${chosen.fee} vs ₦${paidFee} paid). Please retry shortly or contact support.`,
      });
    }

    // Persist a fresh quote row for book-delivery to dispatch from.
    const { data: newQuote, error: quoteErr } = await supabase
      .from("delivery_quotes")
      .insert({
        vendor_id: order.vendor_id,
        buyer_id: order.buyer_id,
        pickup_address: origQuote.pickup_address,
        pickup_landmark: origQuote.pickup_landmark,
        pickup_city: origQuote.pickup_city,
        pickup_latitude: origQuote.pickup_latitude,
        pickup_longitude: origQuote.pickup_longitude,
        delivery_address: origQuote.delivery_address,
        delivery_landmark: origQuote.delivery_landmark,
        delivery_city: origQuote.delivery_city,
        delivery_latitude: origQuote.delivery_latitude,
        delivery_longitude: origQuote.delivery_longitude,
        item_weight: origQuote.item_weight,
        available_couriers: { couriers, sender: bundle.sender, receiver: bundle.receiver, items: bundle.items },
        provider_data: providerData,
        expires_at: new Date(Date.now() + 15 * 60 * 1000).toISOString(),
      })
      .select("id")
      .single();
    if (quoteErr || !newQuote) {
      console.error("request-pickup: failed to store re-quote:", quoteErr);
      return json({ error: "requote_store_failed" }, 500);
    }

    // Delegate the actual booking (wallet gate, label, delivery row, order flag,
    // push) to book-delivery. buyer_charged carries what the buyer actually paid
    // so the delivery row reconciles paid-vs-cost.
    const bookRes = await fetch(`${supabaseUrl}/functions/v1/book-delivery`, {
      method: "POST",
      headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        order_id,
        quote_id: newQuote.id,
        selected_option_ref: chosen.optionRef,
        vendor_id: order.vendor_id,
        buyer_charged: paidFee,
      }),
    });
    const bookData = await bookRes.json().catch(() => ({}));
    if (!bookRes.ok) {
      // Order untouched; surface a friendly reason to the vendor.
      return json({ booked: false, reason: bookData.error || "booking_failed", message: bookData.message }, bookRes.status);
    }

    return json({ booked: true, ...bookData });
  } catch (error: any) {
    console.error("request-pickup error:", error);
    return json({ error: error.message }, 500);
  }
});
