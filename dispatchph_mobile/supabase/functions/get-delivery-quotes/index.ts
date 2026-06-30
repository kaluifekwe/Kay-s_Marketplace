import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { quoteAll } from "../_shared/delivery/orchestrate.ts";
import type { Address, PackageItem } from "../_shared/delivery/types.ts";

// Fetch live courier rates at CHECKOUT across every enabled provider
// (Shipbubble, Terminal Africa, …) and return a merged, cheapest-first list.
// Orders don't exist yet here (created post-payment), so quotes are keyed by
// buyer + vendor + cart. An empty couriers array => client falls back to the
// in-chat delivery-fee negotiation.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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

// Our records store "FCT (Abuja)"; derive a clean state from the delivery city.
function stateForCity(city?: string): string {
  switch ((city || "").toLowerCase()) {
    case "lagos":
      return "Lagos";
    case "abuja":
      return "FCT (Abuja)";
    case "port harcourt":
      return "Rivers";
    default:
      return "";
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    if (!callerId) return json({ error: "Unauthorized" }, 401);

    const {
      vendor_id,
      buyer_id,
      delivery_address,
      delivery_landmark,
      delivery_city,
      delivery_state,
      delivery_latitude,
      delivery_longitude,
      items,
    } = await req.json();

    if (buyer_id !== callerId) return json({ error: "Forbidden" }, 403);
    if (!vendor_id || !buyer_id || !delivery_address || !Array.isArray(items) || items.length === 0) {
      return json({ error: "Missing required fields: vendor_id, buyer_id, delivery_address, items" }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Vendor's default pickup location is the sender. None => not set up for
    // courier delivery; client falls back to chat.
    const { data: pickup } = await supabase
      .from("vendor_locations")
      .select("address, landmark, city, state, latitude, longitude")
      .eq("vendor_id", vendor_id)
      .order("is_default", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!pickup) return json({ quote_id: null, couriers: [], reason: "vendor_no_pickup_location" });

    const { data: vendorUser } = await supabase.from("users").select("name, email, phone").eq("id", vendor_id).maybeSingle();
    const { data: buyerUser } = await supabase.from("users").select("name, email, phone").eq("id", buyer_id).maybeSingle();

    const sender: Address = {
      name: vendorUser?.name || "Vendor",
      email: vendorUser?.email || "vendor@kaysmarketplace.ng",
      phone: vendorUser?.phone || "08000000000",
      address: pickup.address,
      landmark: pickup.landmark,
      city: pickup.city,
      state: pickup.state || stateForCity(pickup.city),
      latitude: pickup.latitude,
      longitude: pickup.longitude,
    };
    const receiver: Address = {
      name: buyerUser?.name || "Buyer",
      email: buyerUser?.email || "buyer@kaysmarketplace.ng",
      phone: buyerUser?.phone || "08000000000",
      address: delivery_address,
      landmark: delivery_landmark,
      city: delivery_city,
      // Use the real state stored on the buyer's address; couriers zone-price by
      // state, so this is what makes the fee vary by destination. Fall back to
      // the 3-city lookup only when the address has no state.
      state: delivery_state || stateForCity(delivery_city),
      latitude: delivery_latitude,
      longitude: delivery_longitude,
    };
    const packageItems: PackageItem[] = items.map((i: any) => ({
      name: i.name,
      weight: Number(i.weight) || 0.5,
      quantity: Number(i.quantity) || 1,
      amount: Number(i.amount) || 0,
    }));
    const totalWeight = packageItems.reduce((s, i) => s + i.weight * i.quantity, 0);

    // Fan out to every enabled provider, merge, sort cheapest-first.
    const { couriers, providerData, reason } = await quoteAll({ sender, receiver, items: packageItems });

    if (couriers.length === 0) {
      return json({ quote_id: null, couriers: [], reason });
    }

    const { data: quote, error: quoteError } = await supabase
      .from("delivery_quotes")
      .insert({
        vendor_id,
        buyer_id,
        pickup_address: pickup.address,
        pickup_landmark: pickup.landmark,
        pickup_city: pickup.city,
        pickup_latitude: pickup.latitude,
        pickup_longitude: pickup.longitude,
        delivery_address,
        delivery_landmark,
        delivery_city,
        delivery_latitude,
        delivery_longitude,
        item_weight: totalWeight,
        available_couriers: { couriers, sender, receiver, items: packageItems },
        provider_data: providerData,
        expires_at: new Date(Date.now() + 15 * 60 * 1000).toISOString(),
      })
      .select("id")
      .single();

    if (quoteError) {
      console.error("Failed to store quote:", quoteError);
      return json({ error: "Failed to store quote" }, 500);
    }

    const mapped = couriers.map((c) => ({
      provider: c.provider,
      option_ref: c.optionRef,
      name: c.name,
      logo: c.logo,
      fee: c.fee,
      currency: c.currency,
      eta: c.eta,
    }));

    return json({ quote_id: quote.id, couriers: mapped });
  } catch (error: any) {
    console.error("get-delivery-quotes error:", error);
    return json({ error: error.message }, 500);
  }
});
