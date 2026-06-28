// Enabled delivery providers, driven by the DELIVERY_PROVIDERS secret
// (comma-separated, e.g. "shipbubble,terminal"). Defaults to shipbubble only,
// so adding a provider is: write the adapter, register it here, flip the env.
import type { DeliveryProvider } from "./types.ts";
import { shipbubble } from "./providers/shipbubble.ts";
import { terminal } from "./providers/terminal.ts";

const ALL: Record<string, DeliveryProvider> = {
  shipbubble,
  terminal,
};

export function enabledProviders(): DeliveryProvider[] {
  const ids = (Deno.env.get("DELIVERY_PROVIDERS") ?? "shipbubble")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return ids.map((id) => ALL[id]).filter(Boolean);
}

export function providerById(id: string): DeliveryProvider | undefined {
  return ALL[id];
}
