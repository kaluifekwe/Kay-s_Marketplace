// Terminal Africa (TShip) provider adapter.
// Flow: GET /packaging (cached) -> POST /addresses x2 -> POST /parcels
//       -> GET /rates/shipment  (quote)
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

const KEY = Deno.env.get("TERMINAL_API_KEY") ?? "";
// Test keys only work against the sandbox host; override for production.
const BASE = Deno.env.get("TERMINAL_BASE_URL") ?? "https://sandbox.terminal.africa/v1";

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

// Terminal requires a zip/postcode to arrange deliveries; our address records
// don't store one, so use a representative postcode per supported city.
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
      zip: cityZip(a.city),
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

    // Rates-by-address: Terminal auto-creates a shipment behind each rate and
    // returns its id on the rate (rate.shipment). We keep that id per option so
    // book() can arrange the pickup against (shipment_id, rate_id).
    // Single-parcel endpoint is a GET with query params (parcel_id, addresses).
    const ratesQuery = new URLSearchParams({
      currency: "NGN",
      pickup_address: from.id,
      delivery_address: to.id,
      parcel_id: parcelId,
    });
    const ratesRes = await api(`/rates/shipment?${ratesQuery.toString()}`);
    const rates = ratesRes.data?.data;
    if (!ratesRes.ok || !Array.isArray(rates) || rates.length === 0) {
      return { provider: "terminal", couriers: [], providerData: {}, reason: `no_rates (${ratesRes.data?.message ?? "empty"})` };
    }

    const couriers: CourierOption[] = rates.map((r: any) => ({
      provider: "terminal",
      optionRef: r.rate_id,
      name: r.carrier_name ?? "Courier",
      logo: r.carrier_logo,
      fee: Number(r.amount),
      currency: r.currency ?? "NGN",
      eta: r.delivery_time,
      meta: { shipment: r.shipment }, // shipment id needed by /shipments/pickup
    }));

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
    };
    const status = map[raw] ?? "in_transit";
    return { providerOrderId, status, courierName: d.carrier?.name };
  },
};
