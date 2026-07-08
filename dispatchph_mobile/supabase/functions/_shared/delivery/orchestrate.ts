// Single source of truth for fetching courier rates across all enabled
// providers. Used by get-delivery-quotes (checkout) and request-pickup
// (vendor-ready re-quote) so the merge logic lives in exactly one place.
import { enabledProviders } from "./registry.ts";
import type { CourierOption, QuoteInput } from "./types.ts";

export interface MergedQuote {
  couriers: CourierOption[]; // fastest-first (price tiebreak) across all providers
  providerData: Record<string, unknown>; // per-provider opaque blob (by provider id)
  reason: string; // joined per-provider reasons when couriers is empty
}

// Provider ETAs are free-text and differ by provider (Terminal: "Same day
// delivery", "Within 1 business day"; Shipbubble: "1 - 2 days", "3 days", …).
// Normalize to an estimated number of days so options can be ranked by speed.
// Unparseable strings return a large sentinel so they sink below anything with a
// known ETA (and then order by price among themselves).
const ETA_UNKNOWN = 999;
export function etaDays(eta?: string): number {
  if (!eta) return ETA_UNKNOWN;
  const s = eta.toLowerCase();
  // Same-day / instant / hours-based delivery ranks fastest.
  if (/same[\s-]?day|instant|today|within\s+hours?|\bhours?\b/.test(s)) return 0;
  if (/next[\s-]?day|tomorrow/.test(s)) return 1;
  // First number in the string is the (lower bound of the) day estimate,
  // e.g. "1 - 2 days" -> 1, "Within 3 business days" -> 3.
  const m = s.match(/\d+/);
  if (m) {
    const n = Number(m[0]);
    if (Number.isFinite(n)) return /week/.test(s) ? n * 7 : n;
  }
  return ETA_UNKNOWN;
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

  // Fastest-first: rank by estimated delivery days, then cheapest as tiebreaker.
  // Buyers care about timing first; among equally fast options the cheaper wins.
  couriers.sort((a, b) => {
    const d = etaDays(a.eta) - etaDays(b.eta);
    return d !== 0 ? d : a.fee - b.fee;
  });
  return { couriers, providerData, reason: reasons.join(" | ") || "no_rates" };
}
