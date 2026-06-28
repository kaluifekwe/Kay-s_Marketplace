// Single source of truth for fetching courier rates across all enabled
// providers. Used by get-delivery-quotes (checkout) and request-pickup
// (vendor-ready re-quote) so the merge logic lives in exactly one place.
import { enabledProviders } from "./registry.ts";
import type { CourierOption, QuoteInput } from "./types.ts";

export interface MergedQuote {
  couriers: CourierOption[]; // cheapest-first across all providers
  providerData: Record<string, unknown>; // per-provider opaque blob (by provider id)
  reason: string; // joined per-provider reasons when couriers is empty
}

export async function quoteAll(input: QuoteInput): Promise<MergedQuote> {
  const providers = enabledProviders();
  const results = await Promise.allSettled(providers.map((p) => p.getQuotes(input)));

  const providerData: Record<string, unknown> = {};
  const couriers: CourierOption[] = [];
  const reasons: string[] = [];

  results.forEach((r, idx) => {
    const pid = providers[idx].id;
    if (r.status !== "fulfilled") {
      reasons.push(`${pid}:error:${r.reason}`);
      return;
    }
    providerData[pid] = r.value.providerData;
    if (r.value.couriers.length) couriers.push(...r.value.couriers);
    else if (r.value.reason) reasons.push(`${pid}:${r.value.reason}`);
  });

  couriers.sort((a, b) => a.fee - b.fee);
  return { couriers, providerData, reason: reasons.join(" | ") || "no_rates" };
}
