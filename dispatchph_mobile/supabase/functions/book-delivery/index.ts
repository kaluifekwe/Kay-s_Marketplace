import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Books a courier with Shipbubble for an already-paid order. Called by
// paystack-webhook (service role) immediately after the order is created, so
// the checkout quote is still fresh. The delivery fee was already collected
// from the buyer into escrow; Shipbubble is paid from the platform's prepaid
// wallet, so this gates on wallet balance first.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const shipbubbleKey = Deno.env.get("SHIPBUBBLE_API_KEY")!;

const SHIPBUBBLE_BASE = "https://api.shipbubble.com/v1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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

async function alertAdminsLowBalance(supabase: any, balance: number, needed: number) {
  const { data: admins } = await supabase.from("users").select("id").eq("role", "admin");
  for (const admin of admins || []) {
    await sendPush(
      admin.id,
      "⚠️ Shipbubble wallet low",
      `Balance ₦${balance} can't cover a ₦${needed} delivery. Top up to keep courier bookings working.`,
      { type: "wallet_low" }
    );
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Booking spends platform money — restrict to service-role callers
    // (the webhook). Buyers/vendors never call this directly.
    if (!isServiceRoleCall(req.headers.get("Authorization"))) {
      return new Response(JSON.stringify({ error: "Forbidden" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { order_id, quote_id, selected_courier_name, delivery_note, vendor_id } = await req.json();

    if (!order_id || !quote_id || !selected_courier_name) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: order_id, quote_id, selected_courier_name" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: quote } = await supabase.from("delivery_quotes").select("*").eq("id", quote_id).maybeSingle();
    if (!quote) {
      return new Response(JSON.stringify({ error: "Quote not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (quote.expires_at && new Date(quote.expires_at) < new Date()) {
      return new Response(
        JSON.stringify({ error: "quote_expired", message: "Delivery quote expired before booking." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const couriersPayload = quote.available_couriers || {};
    const couriers = couriersPayload.couriers || [];
    const requestToken = couriersPayload.request_token;
    const selected = couriers.find((c: any) => c.courier_name === selected_courier_name);

    if (!selected) {
      return new Response(
        JSON.stringify({ error: "Selected courier not in quote" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const courierCost = Number(selected.total);

    // Wallet balance gate (live from Shipbubble; cache to shipbubble_wallet).
    const balanceRes = await fetch(`${SHIPBUBBLE_BASE}/billing/wallet`, {
      headers: { Authorization: `Bearer ${shipbubbleKey}` },
    });
    const balanceData = await balanceRes.json();
    const walletBalance = Number(balanceData.data?.balance ?? 0);
    await supabase
      .from("shipbubble_wallet")
      .update({ balance: walletBalance, last_checked_at: new Date().toISOString(), updated_at: new Date().toISOString() })
      .neq("id", "00000000-0000-0000-0000-000000000000");

    if (walletBalance < courierCost) {
      await alertAdminsLowBalance(supabase, walletBalance, courierCost);
      return new Response(
        JSON.stringify({
          error: "delivery_unavailable",
          message: "Delivery temporarily unavailable. Please try again or contact support.",
        }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Create the shipment label.
    const bookingRes = await fetch(`${SHIPBUBBLE_BASE}/shipping/labels`, {
      method: "POST",
      headers: { Authorization: `Bearer ${shipbubbleKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        request_token: requestToken,
        service_code: selected.service_code,
        courier_id: selected.courier_id,
        sender_address_code: quote.sender_address_code,
        reciever_address_code: quote.receiver_address_code,
        pickup_date: new Date().toISOString().split("T")[0],
        package_items: quote.package_items,
        package_dimension: { length: 10, width: 10, height: 10 },
        delivery_instructions: delivery_note ?? "",
      }),
    });
    const bookingData = await bookingRes.json();

    if (!bookingRes.ok || bookingData.status !== "success") {
      console.error("Shipbubble label creation failed:", bookingData);
      return new Response(
        JSON.stringify({ error: "booking_failed", message: bookingData.message || "Courier booking failed" }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const shipment = bookingData.data;
    const firstItem = (quote.package_items || [])[0] || {};

    const { data: delivery, error: deliveryError } = await supabase
      .from("deliveries")
      .insert({
        order_id,
        vendor_id: vendor_id || quote.vendor_id,
        buyer_id: quote.buyer_id,
        shipbubble_order_id: shipment.order_id,
        courier_name: shipment.courier?.name ?? selected.courier_name,
        courier_phone: shipment.courier?.phone,
        courier_email: shipment.courier?.email,
        tracking_code: shipment.courier?.tracking_code ?? shipment.tracking_code,
        tracking_url: shipment.tracking_url,
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
        item_description: firstItem.description,
        item_weight: quote.item_weight,
        item_quantity: firstItem.quantity ?? 1,
        item_amount: firstItem.unit_amount ?? 0,
        shipbubble_fee: courierCost,
        kays_markup: 0,
        buyer_charged: courierCost,
        status: "pending",
      })
      .select("id")
      .single();

    if (deliveryError) {
      console.error("Failed to insert delivery:", deliveryError);
      return new Response(JSON.stringify({ error: "Failed to record delivery" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
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

    await sendPush(
      quote.buyer_id,
      "🚚 Courier Booked!",
      `${shipment.courier?.name ?? selected.courier_name} will pick up your order soon.`,
      { type: "courier_booked", order_id, delivery_id: delivery.id, screen: "order_tracking" }
    );

    return new Response(
      JSON.stringify({
        delivery_id: delivery.id,
        shipbubble_order_id: shipment.order_id,
        courier_name: shipment.courier?.name ?? selected.courier_name,
        tracking_url: shipment.tracking_url,
        status: "booked",
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: any) {
    console.error("book-delivery error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
