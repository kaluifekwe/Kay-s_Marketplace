// Shipbubble provider adapter — the existing integration lifted behind the
// DeliveryProvider interface. Behavior matches the prior get-delivery-quotes /
// book-delivery (name sanitizing, dynamic category, package_dimension, wallet
// gate). DB side effects (wallet cache, admin alerts) live in the orchestrating
// functions, not here, so this stays pure HTTP.
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

const KEY = Deno.env.get("SHIPBUBBLE_API_KEY") ?? "";
const BASE = "https://api.shipbubble.com/v1";

function headers() {
  return { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };
}

// Shipbubble rejects names with digits/symbols and wants a two-word "full name".
function cleanName(raw: string | null | undefined, fallback: string): string {
  const words = (raw || "").replace(/[^A-Za-z\s]/g, " ").replace(/\s+/g, " ").trim().split(" ").filter(Boolean);
  if (words.length === 0) return fallback;
  if (words.length === 1) return `${words[0]} ${fallback.split(" ").pop()}`;
  return words.join(" ");
}

async function validateAddress(a: Address, fallbackName: string): Promise<{ code: string | null; message?: string }> {
  const res = await fetch(`${BASE}/shipping/address/validate`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify({
      name: cleanName(a.name, fallbackName),
      email: a.email || "user@kaysmarketplace.ng",
      phone: a.phone || "08000000000",
      address: a.address,
      latitude: a.latitude ?? undefined,
      longitude: a.longitude ?? undefined,
    }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.status !== "success") {
    const msg = data?.message ?? JSON.stringify(data);
    return { code: null, message: String(msg).slice(0, 160) };
  }
  return { code: data.data?.address_code ?? null };
}

let cachedCategoryId: number | null = null;
async function getCategoryId(): Promise<number | null> {
  if (cachedCategoryId !== null) return cachedCategoryId;
  try {
    const res = await fetch(`${BASE}/shipping/labels/categories`, { headers: headers() });
    const data = await res.json();
    const cats = data?.data;
    if (Array.isArray(cats) && cats.length > 0) {
      const preferred = cats.find((c: any) => /other|general|miscellaneous/i.test(c.category ?? "")) ?? cats[0];
      cachedCategoryId = Number(preferred.category_id);
      return cachedCategoryId;
    }
  } catch (e) {
    console.error("Shipbubble categories fetch failed:", e);
  }
  return null;
}

export const shipbubble: DeliveryProvider = {
  id: "shipbubble",

  async getQuotes(input: QuoteInput): Promise<ProviderQuote> {
    if (!KEY) return { provider: "shipbubble", couriers: [], providerData: {}, reason: "no_api_key" };

    // Resolve both addresses + the package category CONCURRENTLY — they're
    // independent, so this removes ~2 sequential round-trips from every quote.
    const [sender, receiver, categoryId] = await Promise.all([
      validateAddress(input.sender, "Kay Vendor"),
      validateAddress(input.receiver, "Kay Customer"),
      getCategoryId(),
    ]);
    if (!sender.code || !receiver.code) {
      return {
        provider: "shipbubble",
        couriers: [],
        providerData: {},
        reason: `address_validation_failed (sender:${sender.code ? "ok" : sender.message} | receiver:${receiver.code ? "ok" : receiver.message})`,
      };
    }

    if (categoryId === null) {
      return { provider: "shipbubble", couriers: [], providerData: {}, reason: "no_rates (could not resolve package category)" };
    }

    const packageItems = input.items.map((i) => ({
      name: i.name,
      description: i.name,
      unit_weight: i.weight ?? 0.5,
      unit_amount: i.amount,
      quantity: i.quantity ?? 1,
    }));
    const totalWeight = packageItems.reduce((s, i) => s + Number(i.unit_weight) * Number(i.quantity), 0);

    const ratesRes = await fetch(`${BASE}/shipping/fetch_rates`, {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({
        sender_address_code: sender.code,
        reciever_address_code: receiver.code, // Shipbubble's spelling
        pickup_date: new Date().toISOString().split("T")[0],
        category_id: categoryId,
        package_items: packageItems,
        package_dimension: { length: 10, width: 10, height: 10 },
      }),
    });
    const ratesData = await ratesRes.json().catch(() => ({}));
    const list = ratesData?.data?.couriers;
    if (!ratesRes.ok || ratesData.status !== "success" || !Array.isArray(list) || list.length === 0) {
      const detail = `status=${ratesData?.status} msg=${ratesData?.message ?? "none"}`;
      return { provider: "shipbubble", couriers: [], providerData: {}, reason: `no_rates (${detail.slice(0, 140)})` };
    }

    const couriers: CourierOption[] = list.map((c: any) => ({
      provider: "shipbubble",
      optionRef: `${c.service_code}:${c.courier_id}`,
      name: c.courier_name,
      logo: c.courier_image,
      fee: Number(c.total),
      currency: "NGN",
      eta: c.delivery_eta ?? c.delivery_eta_time,
      meta: { service_code: c.service_code, courier_id: c.courier_id },
    }));

    return {
      provider: "shipbubble",
      couriers,
      providerData: {
        sender_address_code: sender.code,
        receiver_address_code: receiver.code,
        request_token: ratesData.data.request_token,
        package_items: packageItems,
        item_weight: totalWeight,
      },
    };
  },

  async book(input: BookInput): Promise<BookResult> {
    const pd = input.providerData as any;
    const meta = (input.option.meta ?? {}) as any;

    // Platform pays Shipbubble from its prepaid wallet — gate on balance.
    const balRes = await fetch(`${BASE}/billing/wallet`, { headers: headers() });
    const balData = await balRes.json().catch(() => ({}));
    const balance = Number(balData?.data?.balance ?? 0);
    if (balance < input.option.fee) {
      return { ok: false, errorCode: "wallet_low", message: `balance ${balance} < fee ${input.option.fee}` };
    }

    const res = await fetch(`${BASE}/shipping/labels`, {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({
        request_token: pd.request_token,
        service_code: meta.service_code,
        courier_id: meta.courier_id,
        sender_address_code: pd.sender_address_code,
        reciever_address_code: pd.receiver_address_code,
        pickup_date: new Date().toISOString().split("T")[0],
        package_items: pd.package_items,
        package_dimension: { length: 10, width: 10, height: 10 },
        delivery_instructions: input.deliveryNote ?? "",
      }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.status !== "success") {
      return { ok: false, errorCode: "failed", message: data?.message ?? "label creation failed" };
    }
    const s = data.data;
    return {
      ok: true,
      providerOrderId: s.order_id,
      courierName: s.courier?.name ?? input.option.name,
      courierPhone: s.courier?.phone,
      trackingUrl: s.tracking_url,
      fee: input.option.fee,
    };
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  async parseWebhook(_req: Request, body: unknown): Promise<WebhookEvent | null> {
    const p = body as { order_id?: string; status?: string; courier?: any } | null;
    if (!p?.order_id) return null;
    const map: Record<string, DeliveryStatus> = {
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
    // Don't fabricate an "in_transit" from an unknown status (that would wrongly
    // advance an order — e.g. a "rejected"/"returned" cancel). Skip + log unknowns.
    const status = map[(p.status ?? "").toLowerCase()];
    if (!status) {
      console.warn(`shipbubble parseWebhook: unmapped status "${p.status}"`);
      return null;
    }
    return {
      providerOrderId: p.order_id,
      status,
      courierName: p.courier?.name,
      courierPhone: p.courier?.phone,
    };
  },
};
