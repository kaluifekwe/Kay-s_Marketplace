// Hash a withdrawal PIN. A 4-digit PIN has only 10,000 combinations, so we
//  (a) mix in a server-side secret pepper (WITHDRAWAL_PIN_SECRET) so a leaked
//      hash can't be brute-forced offline without the secret, and
//  (b) bind it to the user id so identical PINs hash differently per user.
// Verification + lockout live in the edge functions that call this.
const PEPPER = Deno.env.get("WITHDRAWAL_PIN_SECRET") ?? "";

export async function hashPin(userId: string, pin: string): Promise<string> {
  const data = new TextEncoder().encode(`${userId}:${pin}:${PEPPER}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
