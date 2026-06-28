// TEMPLATE for a new delivery provider. To add an aggregator/carrier:
//   1. Copy this file to providers/<name>.ts and rename the export.
//   2. Implement getQuotes / book / parseWebhook against the provider's API.
//   3. Register it in ../registry.ts (add to the ALL map).
//   4. Add its secret:  supabase secrets set <NAME>_API_KEY=...
//   5. Enable it:       supabase secrets set DELIVERY_PROVIDERS=shipbubble,terminal,<name>
//   6. (If it has webhooks) copy ../../terminal-webhook -> <name>-webhook, add
//      [functions.<name>-webhook] verify_jwt=false to config.toml, deploy, and
//      register the URL in the provider dashboard.
// No changes to get-delivery-quotes / book-delivery are needed — they iterate
// whatever the registry returns. See README.md.
import type {
  BookInput,
  BookResult,
  CourierOption,
  DeliveryProvider,
  ProviderQuote,
  QuoteInput,
  WebhookEvent,
} from "../types.ts";

const KEY = Deno.env.get("EXAMPLE_API_KEY") ?? "";
const BASE = Deno.env.get("EXAMPLE_BASE_URL") ?? "https://api.example.com/v1";

export const example: DeliveryProvider = {
  id: "example",

  async getQuotes(input: QuoteInput): Promise<ProviderQuote> {
    if (!KEY) return { provider: "example", couriers: [], providerData: {}, reason: "no_api_key" };

    // TODO: call the provider's rate endpoint using input.sender / input.receiver
    // / input.items. On any failure return an empty couriers list with a `reason`
    // string (it surfaces in logs + the merged checkout fallback).
    const couriers: CourierOption[] = [
      // {
      //   provider: "example",
      //   optionRef: "<unique id used to book THIS option>",
      //   name: "Carrier Name",
      //   fee: 1500,
      //   currency: "NGN",
      //   eta: "1-2 days",
      //   meta: { /* anything book() needs for this option */ },
      // },
    ];

    // Persist anything book() will need later (ids, tokens) — opaque blob.
    const providerData: Record<string, unknown> = {};

    if (couriers.length === 0) {
      return { provider: "example", couriers: [], providerData, reason: "not_implemented" };
    }
    return { provider: "example", couriers, providerData };
  },

  async book(input: BookInput): Promise<BookResult> {
    // TODO: book input.option using input.option.optionRef / input.option.meta and
    // the input.providerData saved at quote time. If the provider bills a prepaid
    // wallet, gate on balance and return { ok:false, errorCode:"wallet_low" }.
    return { ok: false, errorCode: "failed", message: "not_implemented" };
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  async parseWebhook(_req: Request, body: unknown): Promise<WebhookEvent | null> {
    // TODO: map the provider's webhook payload to a normalized event. Return null
    // for events you don't handle (the webhook function will ack them).
    // status MUST be one of DeliveryStatus.
    void body;
    return null;
  },
};
