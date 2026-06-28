import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { providerById } from "../_shared/delivery/registry.ts";
import type { CourierOption } from "../_shared/delivery/types.ts";

// Books a courier for an already-paid order by dispatching to whichever provider
// owns the chosen quote option. Called by paystack-webhook (service role) right
// after the order is created. The delivery fee is already in escrow; each
// provider pays its carrier from the platform's prepaid wallet.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

function isServiceRoleCall(authHeader: string | null): boolean {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return false;
  return authHeader.replace("Bearer ", "") === supabaseServiceKey;
}

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

async function alertAdminsLowBalance(supabase: any, provider: string, needed: number) {
  const { data: admins } = await supabase.from("users").select("id").eq("role", "admin");
  for (const admin of admins || []) {
    await sendPush(admin.id, "⚠️ Courier wallet low", `${provider} can't cover a ₦${needed} delivery. Top up to keep bookings working.`, { type: "wallet_low" });
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    // Spends platform money — restrict to the service-role caller (webhook).
    if (!isServiceRoleCall(req.headers.get("Authorization"))) return json({ error: "Forbidden" }, 403);

    const { order_id, quote_id, selected_option_ref, selected_courier_name, delivery_note, vendor_id } = await req.json();
    if (!order_id || !quote_id || (!selected_option_ref && !selected_courier_name)) {
      return json({ error: "Missing required fields: order_id, quote_id, selected_option_ref|selected_courier_name" }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: quote } = await supabase.from("delivery_quotes").select("*").eq("id", quote_id).maybeSingle();
    if (!quote) return json({ error: "Quote not found" }, 404);
    if (quote.expires_at && new Date(quote.expires_at) < new Date()) {
      return json({ error: "quote_expired", message: "Delivery quote expired before booking." }, 400);
    }

    const bundle = quote.available_couriers || {};
    const couriers: CourierOption[] = bundle.couriers || [];
    const option = couriers.find((c) =>
      selected_option_ref ? c.optionRef === selected_option_ref : c.name === selected_courier_name
    );
    if (!option) return json({ error: "Selected courier not in quote" }, 400);

    const provider = providerById(option.provider);
    if (!provider) return json({ error: `Unknown provider: ${option.provider}` }, 400);

    const providerData = (quote.provider_data || {})[option.provider] || {};
    const result = await provider.book({
      option,
      providerData,
      sender: bundle.sender,
      receiver: bundle.receiver,
      items: bundle.items || [],
      deliveryNote: delivery_note,
    });

    if (!result.ok) {
      if (result.errorCode === "wallet_low") await alertAdminsLowBalance(supabase, option.provider, option.fee);
      const status = result.errorCode === "wallet_low" ? 503 : 502;
      return json({ error: result.errorCode || "booking_failed", message: result.message }, status);
    }

    const firstItem = (bundle.items || [])[0] || {};
    const { data: delivery, error: deliveryError } = await supabase
      .from("deliveries")
      .insert({
        order_id,
        vendor_id: vendor_id || quote.vendor_id,
        buyer_id: quote.buyer_id,
        provider: option.provider,
        provider_order_id: result.providerOrderId,
        shipbubble_order_id: option.provider === "shipbubble" ? result.providerOrderId : null,
        courier_name: result.courierName ?? option.name,
        courier_phone: result.courierPhone,
        tracking_url: result.trackingUrl,
        pickup_address: quote.pickup_address,
        pickup_landmark: quote.pickup_landmark,
        pickup_city: quote.pickup_city,
        pickup_latitude: quote.pickup_latitude,
        pickup_longitude: quote.pickup_longitude,
        delivery_address: quote.delivery_address,
        delivery_landmark: quote.delivery_landmark,
        delivery_city: quote.delivery_city,
        delivery_latitude: quote.delivery_latitude,
        delivery_longitude: quote.delivery_longitude,
        delivery_note,
        item_name: firstItem.name ?? "Order item",
        item_weight: quote.item_weight,
        item_quantity: firstItem.quantity ?? 1,
        item_amount: firstItem.amount ?? 0,
        shipbubble_fee: result.fee ?? option.fee,
        kays_markup: 0,
        buyer_charged: result.fee ?? option.fee,
        status: "pending",
      })
      .select("id")
      .single();

    if (deliveryError) {
      console.error("Failed to insert delivery:", deliveryError);
      return json({ error: "Failed to record delivery" }, 500);
    }

    await supabase
      .from("orders")
      .update({ has_shipbubble_delivery: true, delivery_id: delivery.id, delivery_quote_id: quote_id })
      .eq("id", order_id);

    await supabase.from("delivery_tracking").insert({
      delivery_id: delivery.id,
      status: "pending",
      description: "Courier booking received",
    });

    await sendPush(quote.buyer_id, "🚚 Courier Booked!", `${result.courierName ?? option.name} will pick up your order soon.`, {
      type: "courier_booked",
      order_id,
      delivery_id: delivery.id,
      screen: "order_tracking",
    });

    return json({
      delivery_id: delivery.id,
      provider: option.provider,
      provider_order_id: result.providerOrderId,
      courier_name: result.courierName ?? option.name,
      tracking_url: result.trackingUrl,
      status: "booked",
    });
  } catch (error: any) {
    console.error("book-delivery error:", error);
    return json({ error: error.message }, 500);
  }
});
