// Authentication for functions invoked by pg_cron.
//
// These functions used to authenticate the scheduler by string-comparing the
// bearer token against SUPABASE_SERVICE_ROLE_KEY. That broke silently and
// completely: a project can hold both a legacy JWT service-role key and a newer
// secret key, the dashboard shows one while the platform injects the other, and
// the comparison then fails for a token that is genuinely a service-role
// credential. Every scheduled job returned 403 for weeks while pg_cron reported
// "succeeded", so escrow never auto-released and nothing surfaced it.
//
// The scheduler now carries its own credential in the `x-cron-secret` header.
//
// It is a SEPARATE HEADER, not the bearer token, for a specific reason. Supabase
// verifies a JWT on every function call before our code runs, so a random secret
// in `Authorization` is rejected at the gateway with a 401 and never reaches us.
// The alternative — deploying with JWT verification disabled — would be unsafe
// here, because the reconcile functions also accept an administrator and decode
// that token WITHOUT verifying its signature. Remove the gateway's check and a
// forged token claiming an admin's id would be accepted. So the gateway keeps
// verifying a real JWT in `Authorization` (the anon key is enough), and the
// credential that actually grants scheduler access travels beside it.
//
// Set it once, with a value you generate:
//     supabase secrets set CRON_SECRET=<random string>
// then schedule the jobs to send both headers.

const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const cronSecret = Deno.env.get("CRON_SECRET") ?? "";

/** Constant-time comparison, so a wrong secret cannot be recovered by timing. */
function sameSecret(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** True when the caller is the scheduler, or an operator holding the service key. */
export function isScheduledCaller(req: Request): boolean {
  const secret = req.headers.get("x-cron-secret");
  if (secret && sameSecret(secret.trim(), cronSecret)) return true;

  // Still accepted so an operator can invoke a job by hand, and so nothing
  // breaks if a job is ever scheduled the old way.
  const auth = req.headers.get("Authorization");
  if (auth?.startsWith("Bearer ")) {
    return sameSecret(auth.slice("Bearer ".length).trim(), serviceKey);
  }
  return false;
}

/**
 * Why a call was refused, for the log only. Never returned to the caller: a
 * scheduler that cannot authenticate is an operational fault we need to see,
 * not information to hand to whoever is calling.
 */
export function refusalReason(req: Request): string {
  const secret = req.headers.get("x-cron-secret");
  const auth = req.headers.get("Authorization");
  if (!cronSecret && !serviceKey) return "neither CRON_SECRET nor SUPABASE_SERVICE_ROLE_KEY is set on this function";
  if (!secret && !auth) return "no x-cron-secret header and no Authorization header";
  if (!secret) return "no x-cron-secret header; Authorization did not match the service-role key";
  if (!cronSecret) return "x-cron-secret was sent but CRON_SECRET is not set on this function";
  return `x-cron-secret did not match: received ${secret.trim().length} chars, expected ${cronSecret.length}`;
}
