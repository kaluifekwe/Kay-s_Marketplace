// Flutterwave v4 helper shared by the wallet Edge Functions.
//
// v4 authenticates with OAuth 2.0 client_credentials: exchange CLIENT_ID +
// CLIENT_SECRET for a short-lived (10 min) bearer token at the IdP, then call
// the API with `Authorization: Bearer <token>`. We cache the token at module
// scope so we don't mint a new one on every request.
//
// Base URL is env-driven so we can point at the sandbox
// (https://developersandbox-api.flutterwave.com) while testing and flip to
// production without a code change.

// v4 production base. Override with FLUTTERWAVE_BASE_URL=https://developersandbox-api.flutterwave.com
// for sandbox testing. (NB: api.flutterwave.com is the v3 host — v4 lives here.)
const FLW_BASE = Deno.env.get("FLUTTERWAVE_BASE_URL") || "https://f4bexperience.flutterwave.com";
const CLIENT_ID = Deno.env.get("FLUTTERWAVE_CLIENT_ID") || "";
const CLIENT_SECRET = Deno.env.get("FLUTTERWAVE_CLIENT_SECRET") || "";
const TOKEN_URL =
  "https://idp.flutterwave.com/realms/flutterwave/protocol/openid-connect/token";

let _token: string | null = null;
let _tokenExpiresAt = 0; // epoch ms

export async function getFlwToken(): Promise<string> {
  const now = Date.now();
  // Reuse the cached token until 30s before it expires.
  if (_token && now < _tokenExpiresAt - 30_000) return _token;

  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      grant_type: "client_credentials",
    }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    console.log(`flw-auth failed: status=${res.status} body=${JSON.stringify(data)}`);
  }
  if (!res.ok || !data.access_token) {
    throw new Error(
      `Flutterwave auth failed (${res.status}): ${data.error_description || data.error || "no token"}`
    );
  }
  _token = data.access_token as string;
  _tokenExpiresAt = now + (Number(data.expires_in) || 600) * 1000;
  return _token;
}

export function flwUrl(path: string): string {
  return `${FLW_BASE}${path.startsWith("/") ? path : "/" + path}`;
}

// Optional static-IP relay for endpoints Flutterwave gates behind IP
// whitelisting (transfers). If configured, transfer calls are routed through it.
const RELAY_URL = Deno.env.get("FLUTTERWAVE_RELAY_URL") || "";
const RELAY_SECRET = Deno.env.get("FLUTTERWAVE_RELAY_SECRET") || "";

/// Initiate a payout (POST /direct-transfers). Routes through the static-IP
/// relay when FLUTTERWAVE_RELAY_URL is set (so Flutterwave sees a whitelisted
/// IP); otherwise calls Flutterwave directly (works only from a whitelisted IP
/// or in sandbox). Returns { ok, status, data }.
export async function flwTransfer(
  body: unknown,
  idempotencyKey: string
): Promise<{ ok: boolean; status: number; data: any }> {
  const token = await getFlwToken();
  const key = idempotencyKey.length >= 12 ? idempotencyKey : `${idempotencyKey}-${crypto.randomUUID()}`;

  if (RELAY_URL) {
    const res = await fetch(RELAY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-relay-secret": RELAY_SECRET },
      body: JSON.stringify({ path: "/direct-transfers", token, body, idempotency_key: key, trace_id: key }),
    });
    const data = await res.json().catch(() => ({}));
    return { ok: res.ok, status: res.status, data };
  }
  return flwPost("/direct-transfers", body, key);
}

/// Authenticated GET, routed through the static-IP relay when configured (used
/// to RECONCILE a withdrawal by reading a transfer's real status when its
/// webhook was missed — the same endpoints are IP-gated as the payout itself).
/// Falls back to a direct call when no relay is set. Returns { ok, status, data }.
export async function flwGet(path: string): Promise<{ ok: boolean; status: number; data: any }> {
  const token = await getFlwToken();
  if (RELAY_URL) {
    const res = await fetch(RELAY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-relay-secret": RELAY_SECRET },
      body: JSON.stringify({ path, token, method: "GET", trace_id: `get-${crypto.randomUUID()}` }),
    });
    const data = await res.json().catch(() => ({}));
    return { ok: res.ok, status: res.status, data };
  }
  const res = await fetch(flwUrl(path), { headers: { Authorization: `Bearer ${token}` } });
  const data = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, data };
}

/// Authenticated POST with v4's required idempotency + trace headers (both must
/// be 12-255 chars). Returns { ok, status, data }.
export async function flwPost(
  path: string,
  body: unknown,
  idempotencyKey: string
): Promise<{ ok: boolean; status: number; data: any }> {
  const token = await getFlwToken();
  // Guarantee the 12-char minimum for the trace/idempotency headers.
  const key = idempotencyKey.length >= 12 ? idempotencyKey : `${idempotencyKey}-${crypto.randomUUID()}`;
  const res = await fetch(flwUrl(path), {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "X-Idempotency-Key": key,
      "X-Trace-Id": key,
    },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, data };
}
