// Multi-provider delivery abstraction. Each courier aggregator/carrier (Shipbubble,
// Terminal Africa, Kwik, …) implements DeliveryProvider; get-delivery-quotes fans
// out to all enabled providers and merges to a cheapest-first list, and
// book-delivery dispatches to whichever provider owns the chosen option.

export interface Address {
  name: string;
  email: string;
  phone: string;
  address: string;
  landmark?: string;
  city?: string;
  state?: string;
  latitude?: number | null;
  longitude?: number | null;
}

export interface PackageItem {
  name: string;
  weight: number; // kg
  quantity: number;
  amount: number; // unit value (NGN)
}

export interface QuoteInput {
  sender: Address;
  receiver: Address;
  items: PackageItem[];
}

// One bookable courier option. `optionRef` is unique within a quote and is how
// book() reconstructs the exact selection (provider-specific: a Shipbubble
// service+courier pair, or a Terminal rate_id).
export interface CourierOption {
  provider: string;
  optionRef: string;
  name: string;
  logo?: string;
  fee: number;
  currency: string;
  eta?: string;
  // Provider-specific data needed to book this option, persisted with the quote.
  meta?: Record<string, unknown>;
}

export interface ProviderQuote {
  provider: string;
  couriers: CourierOption[];
  // Opaque per-provider blob persisted on the quote and handed back to book()
  // (e.g. Shipbubble address codes + request_token, Terminal address/parcel ids).
  providerData: Record<string, unknown>;
  reason?: string; // when couriers is empty, why
}

export interface BookInput {
  option: CourierOption; // the chosen option (carries optionRef + meta)
  providerData: Record<string, unknown>;
  sender: Address;
  receiver: Address;
  items: PackageItem[];
  deliveryNote?: string;
}

export interface BookResult {
  ok: boolean;
  providerOrderId?: string;
  courierName?: string;
  courierPhone?: string;
  trackingUrl?: string;
  fee?: number;
  errorCode?: "wallet_low" | "unavailable" | "failed";
  message?: string;
}

export type DeliveryStatus =
  | "pending"
  | "confirmed"
  | "picked_up"
  | "in_transit"
  | "delivered"
  | "failed"
  | "cancelled";

export interface WebhookEvent {
  providerOrderId: string;
  status: DeliveryStatus;
  courierName?: string;
  courierPhone?: string;
}

export interface DeliveryProvider {
  id: string;
  getQuotes(input: QuoteInput): Promise<ProviderQuote>;
  book(input: BookInput): Promise<BookResult>;
  parseWebhook(req: Request, body: unknown): Promise<WebhookEvent | null>;
}
