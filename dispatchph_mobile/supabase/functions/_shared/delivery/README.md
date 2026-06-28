# Delivery providers

Courier rates and bookings go through a small provider abstraction so adding a
new aggregator/carrier is a drop-in adapter — no changes to the orchestrating
functions.

## How it fits together

```
get-delivery-quotes ──> registry.enabledProviders() ──> [provider.getQuotes()]  ─┐
                                                                                  ├─ merge, cheapest-first
checkout shows the merged list; the buyer picks one (carries provider+optionRef) ─┘

book-delivery ──> registry.providerById(option.provider).book()      (after payment)
<name>-webhook ──> provider.parseWebhook() ──> applyDeliveryStatus()  (status updates)
```

- `types.ts` — the `DeliveryProvider` interface and DTOs.
- `registry.ts` — which providers are active, driven by the `DELIVERY_PROVIDERS`
  secret (comma-separated, e.g. `shipbubble,terminal`).
- `providers/*.ts` — one adapter per provider. `_template.ts` is the starting point.
- `apply-status.ts` — shared webhook logic (deliveries/orders/escrow/push). Every
  `*-webhook` function just does provider auth + `parseWebhook`, then calls this.

## Add a provider in 5 steps

1. **Adapter** — copy `providers/_template.ts` to `providers/<name>.ts`, rename the
   export, and implement:
   - `getQuotes(input)` → return `CourierOption[]` (each with a **unique `optionRef`**)
     plus a `providerData` blob you'll need at booking. Empty list + a `reason` on
     no coverage.
   - `book(input)` → book `input.option` using its `optionRef`/`meta` and the saved
     `input.providerData`. Gate on wallet if the provider bills a prepaid balance
     (`errorCode: "wallet_low"`).
   - `parseWebhook(req, body)` → normalize to `{ providerOrderId, status }`.
2. **Register** — add it to the `ALL` map in `registry.ts`.
3. **Secret** — `supabase secrets set <NAME>_API_KEY=... --project-ref <ref>`.
4. **Enable** — `supabase secrets set DELIVERY_PROVIDERS=shipbubble,terminal,<name>`.
5. **Webhook (if any)** — copy `../terminal-webhook` to `../<name>-webhook`, add
   `[functions.<name>-webhook]\nverify_jwt = false` to `config.toml`, `supabase
   functions deploy <name>-webhook`, and register the URL
   (`https://<project>.supabase.co/functions/v1/<name>-webhook`) in the provider's
   dashboard.

Then redeploy `get-delivery-quotes` and `book-delivery` (they bundle the shared
folder). That's it — no orchestration code changes.

## Conventions

- **`optionRef` must be unique within a quote** and must carry (directly or via
  `meta`) everything `book()` needs — provider names can collide across providers.
- **`providerData`** is opaque and persisted on `delivery_quotes.provider_data`
  keyed by provider id; it's handed back to `book()` untouched.
- **Wallet-billed providers** (Shipbubble, Terminal) need a funded balance for
  both address validation and booking; return `errorCode: "wallet_low"` so
  `book-delivery` alerts admins instead of failing silently.
- **Status** returned from `parseWebhook` must be one of `DeliveryStatus`
  (`pending|confirmed|picked_up|in_transit|delivered|failed|cancelled`).

## Current providers

| id | type | base | key secret |
|----|------|------|------------|
| `shipbubble` | aggregator | `api.shipbubble.com/v1` | `SHIPBUBBLE_API_KEY` |
| `terminal` | aggregator (TShip) | `sandbox.terminal.africa/v1` (set `TERMINAL_BASE_URL` for prod) | `TERMINAL_API_KEY` |
