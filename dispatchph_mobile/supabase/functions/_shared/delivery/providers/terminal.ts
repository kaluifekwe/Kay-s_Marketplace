// Terminal Africa (TShip) provider adapter.
// Flow: GET /packaging (cached) -> POST /addresses x2 -> POST /parcels
//       -> GET /rates/shipment/stream, falling back to GET /rates/shipment  (quote)
//       -> POST /shipments/pickup with rate_id  (book)
// Docs: https://docs.terminal.africa/tship
//
// NOTE: We use the SINGLE-parcel rates endpoint (GET /rates/shipment), not the
// multi-parcel one (POST /rates/multi/shipment). Per Terminal support, local
// carriers (GIG/Kwik/Fez/Chowdeck/Redstar/Dellyman) are only rated on the
// single-parcel endpoint; multi-parcel returns DHL only. We always bundle an
// order into one parcel, so single-parcel is the correct call.
import type {
  Address,
  BookInput,
  BookResult,
  CourierOption,
  DeliveryProvider,
  DeliveryStatus,
  ProviderQuote,
  QuoteInput,
  WebhookEvent,
} from "../types.ts";
import { getBool } from "../../settings.ts";

const KEY = Deno.env.get("TERMINAL_API_KEY") ?? "";

// Single source of truth for the host, exported so the status poller cannot
// disagree with the booker.
//
// It used to be read separately in both places with DIFFERENT defaults: booking
// fell back to sandbox, polling fell back to production. While TERMINAL_BASE_URL
// was unset, shipments were therefore created in the sandbox and then looked up
// in production, where those ids do not exist, so every poll returned 400 and
// their status never moved again. Deliveries booked before the variable was set
// are permanently unresolvable for that reason.
//
// Test keys only work against the sandbox host, so sandbox stays the default;
// set TERMINAL_BASE_URL to https://api.terminal.africa/v1 for live keys.
export const TERMINAL_BASE = Deno.env.get("TERMINAL_BASE_URL") ?? "https://sandbox.terminal.africa/v1";
const BASE = TERMINAL_BASE;

function headers() {
  return { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };
}

async function api(path: string, init?: RequestInit): Promise<any> {
  const res = await fetch(`${BASE}${path}`, { ...init, headers: headers() });
  const data = await res.json().catch(() => ({}));
  return { ok: res.ok && data?.status !== false, status: res.status, data };
}

// Terminal needs a valid NG state string; our buyer/vendor records store "FCT (Abuja)".
function normState(state?: string): string {
  if (!state) return "";
  if (/fct|abuja/i.test(state)) return "Abuja";
  return state;
}

// Terminal requires E.164 / international phone format; our records store local
// NG numbers (080…). Normalize to +234…
function toIntlPhone(phone: string): string {
  const p = (phone || "").replace(/[^\d+]/g, "");
  if (p.startsWith("+")) return p;
  if (p.startsWith("234")) return `+${p}`;
  if (p.startsWith("0")) return `+234${p.slice(1)}`;
  return `+234${p}`;
}

// Terminal requires a zip/postcode to arrange deliveries and takes no
// coordinates: it locates the address from line1 + city + state + zip. Our
// address records don't store a postcode, so it is resolved in this order:
//   1. the address's own zip, if a caller ever supplies one
//   2. Google reverse geocode of the picker's lat/lng (same server key as
//      places-proxy; Google's Nigerian postcode coverage is patchy)
//   3. the state capital's NIPOST code, so a Rivers or Oyo address is never
//      sent with a Lagos postcode
//   4. the old per-city default
const GOOGLE_KEY = Deno.env.get("GOOGLE_MAPS_SERVER_KEY") ?? "";
const ZIP_RE = /^\d{6}$/;

// Keyed by coords rounded to ~11m. Bounded so a hot instance can't grow it forever.
const zipCache = new Map<string, string | null>();

async function googlePostcode(lat?: number | null, lng?: number | null): Promise<string | null> {
  if (!GOOGLE_KEY || !Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  const k = `${(lat as number).toFixed(4)},${(lng as number).toFixed(4)}`;
  if (zipCache.has(k)) return zipCache.get(k)!;
  let zip: string | null = null;
  try {
    const url = new URL("https://maps.googleapis.com/maps/api/geocode/json");
    url.searchParams.set("latlng", k);
    url.searchParams.set("result_type", "postal_code");
    url.searchParams.set("key", GOOGLE_KEY);
    const resp = await fetch(url, { signal: AbortSignal.timeout(3000) });
    if (!resp.ok) return null;
    const r = await resp.json();
    // Only a real answer is cached. A quota or auth error (status
    // OVER_QUERY_LIMIT, REQUEST_DENIED) is retried on the next quote.
    if (r.status !== "OK" && r.status !== "ZERO_RESULTS") return null;
    for (const res of r.results ?? []) {
      const c = (res.address_components ?? []).find((c: any) => c.types?.includes("postal_code"));
      if (c && ZIP_RE.test(c.long_name)) {
        zip = c.long_name;
        break;
      }
    }
  } catch (e) {
    // A slow or failed lookup must never block a quote; fall through to the
    // table without caching, so the next quote tries again. Log only the error
    // name: Deno's fetch errors include the request URL, which holds the key.
    console.warn(`terminal postcode lookup failed: ${e instanceof Error ? e.name : "unknown"}`);
    return null;
  }
  if (zipCache.size > 500) zipCache.clear();
  zipCache.set(k, zip);
  return zip;
}

// NIPOST codes for each state capital. Fallback only, used when the
// coordinates give no postcode.
const STATE_ZIP: Record<string, string> = {
  "lagos": "100001",
  "ogun": "110001",
  "oyo": "200001",
  "osun": "230001",
  "kwara": "240001",
  "kogi": "260001",
  "edo": "300001",
  "delta": "320001",
  "ondo": "340001",
  "ekiti": "360001",
  "enugu": "400001",
  "anambra": "420001",
  "abia": "440001",
  "imo": "460001",
  "ebonyi": "480001",
  "rivers": "500001",
  "akwa ibom": "520001",
  "cross river": "540001",
  "kano": "700001",
  "kaduna": "800001",
  "abuja": "900001",
  "niger": "920001",
  "plateau": "930001",
  "benue": "970001",
};

async function resolveZip(a: Address): Promise<{ zip: string; via: string }> {
  if (a.zip && ZIP_RE.test(a.zip)) return { zip: a.zip, via: "address" };
  const g = await googlePostcode(a.latitude, a.longitude);
  if (g) return { zip: g, via: "google" };
  const s = STATE_ZIP[normState(a.state).toLowerCase().replace(/\s+state$/, "")];
  if (s) return { zip: s, via: "state" };
  return { zip: cityZip(a.city), via: "city" };
}

function cityZip(city?: string): string {
  switch ((city || "").toLowerCase()) {
    case "lagos":
      return "100001";
    case "abuja":
      return "900001";
    case "port harcourt":
      return "500001";
    default:
      return "100001";
  }
}

function splitName(name: string): { first: string; last: string } {
  const parts = (name || "").trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return { first: "Kay", last: "Customer" };
  if (parts.length === 1) return { first: parts[0], last: "Customer" };
  return { first: parts[0], last: parts.slice(1).join(" ") };
}

type CarrierError = { carrier_slug?: string; carrier_name?: string; message?: string };
type RatesResult = { rates: any[]; errors: CarrierError[]; via: string; message?: string };

function tryJson(s: string): any {
  try {
    return JSON.parse(s);
  } catch {
    return null;
  }
}

// The stream sends a "start" event, one "carrier" event per carrier, then a
// "complete" event holding every rate plus an `errors` list saying why each
// missing carrier gave no rate. Accepts SSE ("data: {...}") or one JSON object
// per line. Prefers the complete event; otherwise pools the carrier events.
function parseRateStream(text: string): { rates: any[]; errors: CarrierError[]; complete: boolean; message?: string } {
  const events: any[] = [];
  const whole = tryJson(text.trim());
  if (whole) {
    events.push(...(Array.isArray(whole) ? whole : [whole]));
  } else {
    for (const line of text.split(/\r?\n/)) {
      let s = line.trim();
      if (!s || s.startsWith(":") || s.startsWith("event:") || s.startsWith("id:")) continue;
      if (s.startsWith("data:")) s = s.slice(5).trim();
      const o = tryJson(s);
      if (o) events.push(o);
    }
  }
  const done = events.find((e) => e?.type === "complete") ?? (Array.isArray(whole?.data) ? whole : null);
  if (done) {
    return {
      rates: Array.isArray(done.data) ? done.data : [],
      errors: Array.isArray(done.errors) ? done.errors : [],
      complete: true,
      message: done.message,
    };
  }
  const rates = events.filter((e) => e?.type === "carrier").flatMap((e) => (Array.isArray(e.rates) ? e.rates : []));
  return { rates, errors: [], complete: false };
}

// Stream first: it rates the same carriers as GET /rates/shipment but also
// reports per-carrier failures, which the plain endpoint throws away. Any
// problem with the stream (HTTP error, timeout, a body we can't read) falls
// back to the plain endpoint, so checkout behaves exactly as before at worst.
// Switch off with TERMINAL_RATES_STREAM=false.
//
// Both attempts are time-boxed so the worst case (stream times out, then the
// plain call is slow) stays well inside the edge function's wall clock.
const STREAM_TIMEOUT_MS = 20_000;
const SINGLE_TIMEOUT_MS = 25_000;
const STREAM_MAX_BYTES = 2_000_000; // a full rate list is tens of KB

// res.text() with a size cap, so a runaway stream can't exhaust memory.
async function readCapped(res: Response, maxBytes: number): Promise<string> {
  if (!res.body) return "";
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let total = 0;
  let text = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new Error(`stream exceeded ${maxBytes} bytes`);
    }
    text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
}

async function fetchRates(query: URLSearchParams): Promise<RatesResult> {
  if (await getBool("terminal_rates_stream", "TERMINAL_RATES_STREAM", true)) {
    try {
      const res = await fetch(`${BASE}/rates/shipment/stream?${query.toString()}`, {
        headers: { ...headers(), Accept: "text/event-stream, application/json" },
        signal: AbortSignal.timeout(STREAM_TIMEOUT_MS),
      });
      const text = await readCapped(res, STREAM_MAX_BYTES);
      if (res.ok) {
        const parsed = parseRateStream(text);
        if (parsed.rates.length > 0 || parsed.complete) {
          return { rates: parsed.rates, errors: parsed.errors, via: "stream", message: parsed.message };
        }
      }
      console.warn(`terminal stream unusable (http ${res.status}), falling back: ${text.slice(0, 200)}`);
    } catch (e) {
      console.warn("terminal stream failed, falling back:", e);
    }
  }
  const r = await api(`/rates/shipment?${query.toString()}`, { signal: AbortSignal.timeout(SINGLE_TIMEOUT_MS) });
  return {
    rates: r.ok && Array.isArray(r.data?.data) ? r.data.data : [],
    errors: Array.isArray(r.data?.errors) ? r.data.errors : [],
    via: "single",
    message: r.data?.message,
  };
}

let cachedPackaging: string | null = null;
async function packagingId(): Promise<string | null> {
  if (cachedPackaging) return cachedPackaging;
  const { ok, data } = await api("/packaging?perPage=1");
  const list = data?.data?.packaging;
  if (ok && Array.isArray(list) && list.length > 0) {
    cachedPackaging = list[0].packaging_id;
    return cachedPackaging;
  }
  // Fresh account has no packaging defined — create a default box so parcels
  // (and therefore rates) can be built.
  const created = await api("/packaging", {
    method: "POST",
    body: JSON.stringify({
      name: "Kay Default Box",
      type: "box",
      height: 10,
      width: 10,
      length: 10,
      size_unit: "cm",
      weight: 0.5,
      weight_unit: "kg",
    }),
  });
  const pid = created.data?.data?.packaging_id;
  if (created.ok && pid) {
    cachedPackaging = pid;
    return cachedPackaging;
  }
  console.error("Terminal packaging create failed:", created.data);
  return null;
}

async function createAddress(a: Address): Promise<{ id: string | null; message?: string }> {
  const { first, last } = splitName(a.name);
  const { zip, via } = await resolveZip(a);
  console.log(`terminal zip ${zip} via ${via} (${a.city ?? "?"}, ${a.state ?? "?"})`);
  const { ok, data } = await api("/addresses", {
    method: "POST",
    body: JSON.stringify({
      first_name: first,
      last_name: last,
      email: a.email || "customer@kaysmarketplace.ng",
      phone: toIntlPhone(a.phone || "08000000000"),
      // Terminal caps line1 at 45 chars; OSM/Nominatim strings are long.
      line1: (a.address || "").slice(0, 45),
      city: a.city || "",
      state: normState(a.state),
      country: "NG",
      zip,
      is_residential: true,
    }),
  });
  if (ok && data?.data?.address_id) return { id: data.data.address_id };
  return { id: null, message: data?.message ?? "address create failed" };
}

export const terminal: DeliveryProvider = {
  id: "terminal",

  async getQuotes(input: QuoteInput): Promise<ProviderQuote> {
    if (!KEY) return { provider: "terminal", couriers: [], providerData: {}, reason: "no_api_key" };

    // Packaging + both addresses are independent — create them CONCURRENTLY so
    // Terminal isn't three sequential round-trips before we can even ask for rates.
    const [pkg, from, to] = await Promise.all([
      packagingId(),
      createAddress(input.sender),
      createAddress(input.receiver),
    ]);
    if (!pkg) return { provider: "terminal", couriers: [], providerData: {}, reason: "no_packaging" };
    if (!from.id || !to.id) {
      return {
        provider: "terminal",
        couriers: [],
        providerData: {},
        reason: `address_failed (sender:${from.id ? "ok" : from.message} | receiver:${to.id ? "ok" : to.message})`,
      };
    }

    const totalWeight = input.items.reduce((s, i) => s + (i.weight || 0.5) * (i.quantity || 1), 0);
    const parcelRes = await api("/parcels", {
      method: "POST",
      body: JSON.stringify({
        packaging: pkg,
        weight_unit: "kg",
        items: input.items.map((i) => ({
          name: i.name,
          description: i.name,
          quantity: i.quantity ?? 1,
          weight: i.weight ?? 0.5,
          value: i.amount,
          currency: "NGN",
        })),
        description: "Marketplace order",
      }),
    });
    const parcelId = parcelRes.data?.data?.parcel_id;
    if (!parcelRes.ok || !parcelId) {
      return { provider: "terminal", couriers: [], providerData: {}, reason: `parcel_failed (${parcelRes.data?.message ?? "no parcel"})` };
    }

    // Rates-by-address with a single parcel_id (both endpoints are GETs with
    // the same query). book() arranges the pickup against the rate_id, plus the
    // draft shipment id when the plain endpoint returned one.
    const ratesQuery = new URLSearchParams({
      currency: "NGN",
      pickup_address: from.id,
      delivery_address: to.id,
      parcel_id: parcelId,
    });
    const fetched = await fetchRates(ratesQuery);
    const { errors, via, message } = fetched;
    // A rate is only bookable with an id and a real price (0 is allowed).
    const rates = fetched.rates.filter((r: any) => {
      const amount = typeof r?.amount === "string" ? r.amount.trim() : r?.amount;
      return typeof r?.rate_id === "string" && r.rate_id.length > 0 &&
        amount !== null && amount !== undefined && amount !== "" &&
        Number.isFinite(Number(amount)) && Number(amount) >= 0;
    });
    if (rates.length < fetched.rates.length) {
      console.warn(`terminal dropped ${fetched.rates.length - rates.length} rate(s) with no rate_id or price`);
    }

    // One line per quote naming every carrier that did and didn't rate, and why.
    // This is the record that answers "why only Chowdeck for this route?".
    const errorSummary = errors
      .map((e) => `${e.carrier_slug ?? e.carrier_name ?? "?"}: ${e.message ?? "no reason"}`)
      .join("; ");
    console.log(
      `terminal rates via=${via} ok=[${rates.map((r: any) => r.carrier_slug ?? r.carrier_name).join(",")}] ` +
      `errors=[${errorSummary}]`,
    );

    if (rates.length === 0) {
      const why = (errorSummary || message || "empty").slice(0, 300);
      return { provider: "terminal", couriers: [], providerData: {}, reason: `no_rates (${why})` };
    }

    const couriers: CourierOption[] = rates.map((r: any) => {
      // delivery_eta is minutes from now, pickup included.
      const etaMin = Number(r.delivery_eta);
      return {
        provider: "terminal",
        optionRef: r.rate_id,
        name: r.carrier_name ?? "Courier",
        logo: r.carrier_logo,
        fee: Number(r.amount),
        currency: r.currency ?? "NGN",
        eta: r.delivery_time,
        etaHours: Number.isFinite(etaMin) && etaMin > 0 ? etaMin / 60 : undefined,
        // Draft shipment id when the plain endpoint returns one. The stream
        // doesn't, and /shipments/pickup then creates the shipment from the rate.
        meta: { shipment: r.shipment },
      };
    });

    return {
      provider: "terminal",
      couriers,
      providerData: { parcel: parcelId, weight: totalWeight },
    };
  },

  async book(input: BookInput): Promise<BookResult> {
    const meta = (input.option.meta ?? {}) as any;
    const { ok, data } = await api("/shipments/pickup", {
      method: "POST",
      body: JSON.stringify({ rate_id: input.option.optionRef, shipment_id: meta.shipment }),
    });
    if (!ok) {
      const msg = String(data?.message ?? "booking failed");
      const wallet = /wallet|balance|fund/i.test(msg);
      return { ok: false, errorCode: wallet ? "wallet_low" : "failed", message: msg };
    }
    const d = data?.data ?? {};
    return {
      ok: true,
      providerOrderId: d.shipment_id ?? d.id,
      courierName: input.option.name,
      courierPhone: d.carrier?.phone ?? d.rate?.carrier?.phone,
      trackingUrl: d.tracking_url ?? d.tracking_link,
      fee: input.option.fee,
    };
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  async parseWebhook(_req: Request, body: unknown): Promise<WebhookEvent | null> {
    const payload = body as { event?: string; data?: any } | null;
    if (!payload?.data) return null;
    const d = payload.data;
    const providerOrderId = d.shipment_id ?? d.id;
    if (!providerOrderId) return null;

    const raw = String(d.status ?? payload.event ?? "").toLowerCase();
    const map: Record<string, DeliveryStatus> = {
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
      "rejected": "cancelled",
      "shipment.rejected": "cancelled",
      "failed": "failed",
      "shipment.failed": "failed",
      "returned": "failed",
      "shipment.returned": "failed",
      "pickup-failed": "failed",
    };
    // Don't fabricate an "in_transit" from an unknown status — that would wrongly
    // advance an order (e.g. a "rejected" cancel). Skip what we don't recognise.
    const status = map[raw];
    if (!status) {
      console.warn(`terminal parseWebhook: unmapped status "${raw}"`);
      return null;
    }
    return { providerOrderId, status, courierName: d.carrier?.name };
  },
};
