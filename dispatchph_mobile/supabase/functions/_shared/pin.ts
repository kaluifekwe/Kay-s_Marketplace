// Withdrawal PIN hashing. A 4-digit PIN has only 10,000 combinations, so we
//  (a) mix in a server-side secret pepper (WITHDRAWAL_PIN_SECRET) so a leaked
//      hash can't be brute-forced offline without the secret,
//  (b) bind it to the user id so identical PINs hash differently per user, and
//  (c) run it through a slow KDF (PBKDF2-HMAC-SHA256, 100k iterations) so that
//      even if BOTH the DB and the pepper leak, brute-forcing the 10k-combo
//      space is expensive instead of instant.
// Verification + lockout live in the edge functions that call this.
//
// Hashes are VERSIONED so the upgrade is non-breaking:
//   "v2$<hex>"  -> PBKDF2 (current).
//   <64-hex>    -> legacy single-round SHA-256 (v1). Still verified, and
//                  transparently re-hashed to v2 on the next successful verify.

const PEPPER = Deno.env.get("WITHDRAWAL_PIN_SECRET") ?? "";
const PBKDF2_ITERATIONS = 100_000;

function toHex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Constant-time compare of two strings (avoids leaking match position via timing).
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}

// Legacy v1: single-round SHA-256 over userId:pin:pepper.
async function legacyHash(userId: string, pin: string): Promise<string> {
  const data = new TextEncoder().encode(`${userId}:${pin}:${PEPPER}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return toHex(digest);
}

// Current v2: PBKDF2-HMAC-SHA256, salted with userId + pepper.
async function pbkdf2Hash(userId: string, pin: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(pin), { name: "PBKDF2" }, false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: enc.encode(`${userId}:${PEPPER}`), iterations: PBKDF2_ITERATIONS },
    key,
    256,
  );
  return `v2$${toHex(bits)}`;
}

// Produce the current-version hash (used when setting a PIN or upgrading one).
export async function hashPin(userId: string, pin: string): Promise<string> {
  return pbkdf2Hash(userId, pin);
}

// Verify a PIN against a stored hash of either version. Returns whether it
// matched and whether the stored hash should be upgraded to the current version.
export async function verifyPin(
  userId: string,
  pin: string,
  storedHash: string,
): Promise<{ ok: boolean; needsRehash: boolean }> {
  if (storedHash.startsWith("v2$")) {
    const computed = await pbkdf2Hash(userId, pin);
    return { ok: safeEqual(computed, storedHash), needsRehash: false };
  }
  // Legacy v1 (bare SHA-256 hex) — verify, and flag for upgrade if it matched.
  const ok = safeEqual(await legacyHash(userId, pin), storedHash);
  return { ok, needsRehash: ok };
}
