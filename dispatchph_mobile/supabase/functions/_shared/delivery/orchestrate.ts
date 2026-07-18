// Single source of truth for fetching courier rates across all enabled
// providers. Used by get-delivery-quotes (checkout) and request-pickup
// (vendor-ready re-quote) so the merge logic lives in exactly one place.
import { enabledProviders } from "./registry.ts";
import { getNumber } from "../settings.ts";
import type { CourierOption, QuoteInput } from "./types.ts";

export interface MergedQuote {
  couriers: CourierOption[]; // fastest-first (price tiebreak) across all providers
  providerData: Record<string, unknown>; // per-provider opaque blob (by provider id)
  reason: string; // joined per-provider reasons when couriers is empty
}

// Provider ETAs are free-text and differ by provider (Terminal: "Same day
// delivery", "Within 1 business day"; Shipbubble: "1 - 2 days", "3 days", …).
// Normalize to an estimated number of HOURS so options can be ranked by speed
// and filtered against a max-delivery ceiling. Ranges use the LOWER bound
// ("1 - 2 days" -> 24h). Unparseable strings return a large sentinel so they
// sink below anything with a known ETA (and then order by price among themselves).
const ETA_UNKNOWN = 1e9;
export function etaHours(eta?: string): number {
  if (!eta) return ETA_UNKNOWN;
  const s = eta.toLowerCase();
  // Same-day / instant delivery is the fastest tier.
  if (/same[\s-]?day|instant|today/.test(s)) return 0;
  // Explicit hour quotes: "5 hours", "10 hrs", "10hr", "within 24 hours".
  // Take the number attached to an hour unit (hour/hours/hr/hrs) so a large
  // value like "30 hours" is measured as 30h — NOT flattened to "fast" the way
  // a bare same-day match would be. This is what lets the 24h ceiling exclude it.
  const hm = s.match(/(\d+)\s*(?:hours?|hrs?)\b/);
  if (hm) {
    const n = Number(hm[1]);
    if (Number.isFinite(n)) return n;
  }
  // "within hours" with no number → treat as same-day-fast.
  if (/\b(?:hours?|hrs?)\b/.test(s)) return 0;
  // Day-based quotes → convert to hours.
  if (/next[\s-]?day|tomorrow/.test(s)) return 24;
  // First number in the string is the (lower bound of the) day estimate,
  // e.g. "1 - 2 days" -> 1 -> 24h, "Within 3 business days" -> 3 -> 72h.
  const dm = s.match(/\d+/);
  if (dm) {
    const n = Number(dm[0]);
    if (Number.isFinite(n)) return (/week/.test(s) ? n * 7 : n) * 24;
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

  // Speed filter — the marketplace promises QUICK delivery, so only offer options
  // that arrive within MAX_DELIVERY_HOURS (default 24 = same-day / hour-quotes up
  // to 24h / next-day / "within 1 business day" / the lower bound of "1 - 2 days").
  // "2 - 3 days" (48h), "3 days" (72h), "30 hours" and unparseable ETAs are all
  // dropped. When this empties an otherwise non-empty list, push a NON-transient
  // reason: the client treats an empty + transient reason as retryable, but "all
  // too slow" is a genuine no-fast-courier result that should drop straight to
  // the vendor-arranged fallback.
  const maxHours = await getNumber("max_delivery_hours", "MAX_DELIVERY_HOURS", 24);
  const fast = couriers.filter((c) => etaHours(c.eta) <= maxHours);
  if (couriers.length > 0 && fast.length === 0) {
    reasons.push(`all_options_too_slow (max=${maxHours}h)`);
  }
  couriers.length = 0;
  couriers.push(...fast);

  // Fastest-first: rank by estimated delivery hours, then cheapest as tiebreaker.
  // Buyers care about timing first; among equally fast options the cheaper wins.
  couriers.sort((a, b) => {
    const d = etaHours(a.eta) - etaHours(b.eta);
    return d !== 0 ? d : a.fee - b.fee;
  });
  return { couriers, providerData, reason: reasons.join(" | ") || "no_rates" };
}
