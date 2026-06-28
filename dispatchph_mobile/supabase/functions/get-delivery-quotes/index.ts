import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Fetch live Shipbubble courier rates at CHECKOUT. Orders don't exist yet at
// this point (they're created post-payment in paystack-webhook), so the quote
// is keyed by buyer + vendor + cart, NOT order_id. An empty couriers array is
// the client's signal to fall back to the in-chat delivery-fee negotiation.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const shipbubbleKey = Deno.env.get("SHIPBUBBLE_API_KEY")!;

const SHIPBUBBLE_BASE = "https://api.shipbubble.com/v1";

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

// fetch_rates requires a real package category_id from Shipbubble's list
// (the hardcoded "1" returns "Invalid package category selected"). Resolve a
// sensible default once and cache it for the lifetime of the warm instance.
let cachedCategoryId: number | null = null;
async function getCategoryId(): Promise<number | null> {
  if (cachedCategoryId !== null) return cachedCategoryId;
  try {
    const res = await fetch(`${SHIPBUBBLE_BASE}/shipping/labels/categories`, {
      headers: { Authorization: `Bearer ${shipbubbleKey}` },
    });
    const data = await res.json();
    const cats = data?.data;
    if (Array.isArray(cats) && cats.length > 0) {
      const preferred = cats.find((c: any) => /other|general|miscellaneous/i.test(c.category ?? "")) ?? cats[0];
      cachedCategoryId = Number(preferred.category_id);
      return cachedCategoryId;
    }
    console.error("Shipbubble categories empty:", data);
  } catch (e) {
    console.error("Shipbubble categories fetch failed:", e);
  }
  return null;
}

// Shipbubble's address validator rejects names containing digits or symbols
// ("please provide a full name ... remove all numbers and symbols"). Marketplace
// display names often carry unique-id suffixes/emoji, so strip everything but
// letters and spaces and fall back to a safe two-word name.
function cleanName(raw: string | null | undefined, fallback: string): string {
  const words = (raw || "")
    .replace(/[^A-Za-z\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .split(" ")
    .filter((w) => w.length > 0);
  // Shipbubble wants a two-word "full name" with no digits/symbols.
  if (words.length === 0) return fallback;
  if (words.length === 1) return `${words[0]} ${fallback.split(" ").pop()}`;
  return words.join(" ");
}

// Shipbubble requires an address to be validated into an address_code before
// it can be used in fetch_rates. name/phone/email are required by the API.
async function validateAddress(opts: {
  name: string;
  email: string;
  phone: string;
  address: string;
  latitude?: number | null;
  longitude?: number | null;
}): Promise<{ code: string | null; message?: string }> {
  const res = await fetch(`${SHIPBUBBLE_BASE}/shipping/address/validate`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${shipbubbleKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      name: opts.name,
      email: opts.email,
      phone: opts.phone,
      address: opts.address,
      latitude: opts.latitude ?? undefined,
      longitude: opts.longitude ?? undefined,
    }),
  });
  const data = await res.json();
  if (!res.ok || data.status !== "success") {
    console.error("Shipbubble address validate failed:", data);
    const msg = data?.message ?? (typeof data === "object" ? JSON.stringify(data) : String(data));
    return { code: null, message: String(msg).slice(0, 160) };
  }
  return { code: data.data?.address_code ?? null };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({ error: "Method not allowed" }), {
        status: 405,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    if (!callerId) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const {
      vendor_id,
      buyer_id,
      delivery_address,
      delivery_landmark,
      delivery_city,
      delivery_latitude,
      delivery_longitude,
      items, // [{ name, weight, quantity, amount }]
    } = await req.json();

    // Callers may only quote for themselves.
    if (buyer_id !== callerId) {
      return new Response(JSON.stringify({ error: "Forbidden" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (!vendor_id || !buyer_id || !delivery_address || !Array.isArray(items) || items.length === 0) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: vendor_id, buyer_id, delivery_address, items" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Vendor's default pickup location is the sender. No pickup location set =>
    // this vendor isn't set up for courier delivery; client falls back to chat.
    const { data: pickup } = await supabase
      .from("vendor_locations")
      .select("address, landmark, city, latitude, longitude")
      .eq("vendor_id", vendor_id)
      .order("is_default", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!pickup) {
      return new Response(
        JSON.stringify({ quote_id: null, couriers: [], reason: "vendor_no_pickup_location" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Contact details required by Shipbubble's address validation.
    const { data: vendorUser } = await supabase.from("users").select("name, email, phone").eq("id", vendor_id).maybeSingle();
    const { data: buyerUser } = await supabase.from("users").select("name, email, phone").eq("id", buyer_id).maybeSingle();

    const sender = await validateAddress({
      name: cleanName(vendorUser?.name, "Kay Vendor"),
      email: vendorUser?.email || "vendor@kaysmarketplace.ng",
      phone: vendorUser?.phone || "08000000000",
      address: pickup.address,
      latitude: pickup.latitude,
      longitude: pickup.longitude,
    });
    const receiver = await validateAddress({
      name: cleanName(buyerUser?.name, "Kay Customer"),
      email: buyerUser?.email || "buyer@kaysmarketplace.ng",
      phone: buyerUser?.phone || "08000000000",
      address: delivery_address,
      latitude: delivery_latitude,
      longitude: delivery_longitude,
    });
    const senderCode = sender.code;
    const receiverCode = receiver.code;

    if (!senderCode || !receiverCode) {
      // Address couldn't be validated — fall back to chat negotiation. The
      // per-side detail is folded into reason so it surfaces in client logs.
      const detail = `sender:${senderCode ? "ok" : (sender.message || "fail")} | receiver:${receiverCode ? "ok" : (receiver.message || "fail")}`;
      return new Response(
        JSON.stringify({ quote_id: null, couriers: [], reason: `address_validation_failed (${detail})` }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const packageItems = items.map((i: any) => ({
      name: i.name,
      description: i.name,
      unit_weight: i.weight ?? 0.5,
      unit_amount: i.amount,
      quantity: i.quantity ?? 1,
    }));
    const totalWeight = packageItems.reduce((s: number, i: any) => s + Number(i.unit_weight) * Number(i.quantity), 0);

    const categoryId = await getCategoryId();
    if (categoryId === null) {
      return new Response(
        JSON.stringify({ quote_id: null, couriers: [], reason: "no_rates (could not resolve package category)" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const ratesRes = await fetch(`${SHIPBUBBLE_BASE}/shipping/fetch_rates`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${shipbubbleKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        sender_address_code: senderCode,
        reciever_address_code: receiverCode, // Shipbubble's spelling
        pickup_date: new Date().toISOString().split("T")[0],
        category_id: categoryId,
        package_items: packageItems,
        package_dimension: { length: 10, width: 10, height: 10 },
      }),
    });
    const ratesData = await ratesRes.json();

    const courierList = ratesData?.data?.couriers;
    if (!ratesRes.ok || ratesData.status !== "success" || !Array.isArray(courierList) || courierList.length === 0) {
      console.error("Shipbubble fetch_rates failed:", ratesData);
      // Surface the Shipbubble detail so the client log distinguishes a real
      // request error from a route genuinely served by no courier.
      const n = Array.isArray(courierList) ? courierList.length : "n/a";
      const detail = `status=${ratesData?.status} n=${n} msg=${ratesData?.message ?? "none"}`;
      return new Response(
        JSON.stringify({ quote_id: null, couriers: [], reason: `no_rates (${String(detail).slice(0, 160)})` }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const couriers = ratesData.data.couriers;
    const requestToken = ratesData.data.request_token; // needed at booking time

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
        sender_address_code: senderCode,
        receiver_address_code: receiverCode,
        package_items: packageItems,
        available_couriers: { couriers, request_token: requestToken },
        expires_at: new Date(Date.now() + 15 * 60 * 1000).toISOString(),
      })
      .select("id")
      .single();

    if (quoteError) {
      console.error("Failed to store quote:", quoteError);
      return new Response(JSON.stringify({ error: "Failed to store quote" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const mapped = couriers
      .map((c: any) => ({
        name: c.courier_name,
        logo: c.courier_image,
        fee: Number(c.total),
        currency: "NGN",
        eta: c.delivery_eta ?? c.delivery_eta_time,
        service_code: c.service_code,
        courier_id: c.courier_id,
      }))
      .sort((a: any, b: any) => a.fee - b.fee);

    return new Response(
      JSON.stringify({ quote_id: quote.id, couriers: mapped }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: any) {
    console.error("get-delivery-quotes error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
