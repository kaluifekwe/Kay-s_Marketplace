import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// Google Places proxy. Keeps the Places/Geocoding API key server-side (never
// shipped in the app binary) and normalises responses for the Flutter client.
// Auth-gated so only signed-in users can spend the key. Three actions:
//   - autocomplete: text -> address predictions (NG only, optionally city-biased)
//   - details:      place_id -> { address, lat, lng }
//   - reverse:      lat/lng -> formatted address
//
// Session tokens: the client sends one uuid per "search session" on every
// autocomplete call AND the follow-up details call, so Google bills the whole
// session as one unit instead of per keystroke. Set GOOGLE_MAPS_SERVER_KEY via
// `supabase secrets set GOOGLE_MAPS_SERVER_KEY=...`.

const googleKey = Deno.env.get("GOOGLE_MAPS_SERVER_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

// Rough centres for the cities we deliver to, for location-biasing predictions.
const CITY_BIAS: Record<string, { lat: number; lng: number; radius: number }> = {
  "Lagos": { lat: 6.5244, lng: 3.3792, radius: 40000 },
  "Abuja": { lat: 9.0765, lng: 7.3986, radius: 40000 },
  "Port Harcourt": { lat: 4.8156, lng: 7.0498, radius: 40000 },
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

function callerId(authHeader: string | null): string | null {
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
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    if (!callerId(req.headers.get("Authorization"))) return json({ error: "Unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const action = body.action as string | undefined;

    if (action === "autocomplete") {
      const input = (body.input as string | undefined)?.trim() ?? "";
      if (input.length < 3) return json({ predictions: [] });
      const sessionToken = (body.sessionToken as string | undefined) ?? "";
      const url = new URL("https://maps.googleapis.com/maps/api/place/autocomplete/json");
      url.searchParams.set("input", input);
      url.searchParams.set("key", googleKey);
      url.searchParams.set("components", "country:ng");
      url.searchParams.set("language", "en");
      if (sessionToken) url.searchParams.set("sessiontoken", sessionToken);
      const bias = body.city ? CITY_BIAS[body.city as string] : undefined;
      if (bias) {
        url.searchParams.set("location", `${bias.lat},${bias.lng}`);
        url.searchParams.set("radius", String(bias.radius));
      }
      const r = await fetch(url).then((x) => x.json());
      if (r.status !== "OK" && r.status !== "ZERO_RESULTS") {
        console.error("autocomplete error:", r.status, r.error_message);
        return json({ error: "places_failed" }, 502);
      }
      const predictions = (r.predictions ?? []).map((p: any) => ({
        place_id: p.place_id as string,
        description: p.description as string,
        primary: p.structured_formatting?.main_text ?? p.description,
        secondary: p.structured_formatting?.secondary_text ?? "",
      }));
      return json({ predictions });
    }

    if (action === "details") {
      const placeId = body.placeId as string | undefined;
      if (!placeId) return json({ error: "missing_place_id" }, 400);
      const sessionToken = (body.sessionToken as string | undefined) ?? "";
      const url = new URL("https://maps.googleapis.com/maps/api/place/details/json");
      url.searchParams.set("place_id", placeId);
      url.searchParams.set("key", googleKey);
      url.searchParams.set("fields", "geometry,formatted_address,name");
      url.searchParams.set("language", "en");
      if (sessionToken) url.searchParams.set("sessiontoken", sessionToken);
      const r = await fetch(url).then((x) => x.json());
      if (r.status !== "OK") {
        console.error("details error:", r.status, r.error_message);
        return json({ error: "places_failed" }, 502);
      }
      const loc = r.result?.geometry?.location;
      return json({
        address: r.result?.formatted_address ?? r.result?.name ?? "",
        lat: loc?.lat ?? null,
        lng: loc?.lng ?? null,
      });
    }

    if (action === "reverse") {
      const lat = Number(body.lat);
      const lng = Number(body.lng);
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) return json({ error: "missing_latlng" }, 400);
      const url = new URL("https://maps.googleapis.com/maps/api/geocode/json");
      url.searchParams.set("latlng", `${lat},${lng}`);
      url.searchParams.set("key", googleKey);
      url.searchParams.set("language", "en");
      const r = await fetch(url).then((x) => x.json());
      if (r.status !== "OK" && r.status !== "ZERO_RESULTS") {
        console.error("reverse error:", r.status, r.error_message);
        return json({ error: "places_failed" }, 502);
      }
      const address = r.results?.[0]?.formatted_address ?? `${lat}, ${lng}`;
      return json({ address });
    }

    return json({ error: "unknown_action" }, 400);
  } catch (e) {
    console.error("places-proxy error:", e);
    return json({ error: "places_failed" }, 500);
  }
});
