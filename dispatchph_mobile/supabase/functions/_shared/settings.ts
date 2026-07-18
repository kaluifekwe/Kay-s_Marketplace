// Admin-editable business config (app_settings), with a fallback chain that
// makes it impossible for a missing/broken row to change behaviour:
//
//     app_settings row  ->  environment variable  ->  hardcoded default
//
// So every call site keeps the literal it used before as its final fallback: if
// the table is empty, unreachable, or holds a junk value, the function behaves
// exactly as it did prior to the config layer.
//
// Values are cached at module scope for CACHE_TTL_MS. Edge function instances
// are reused between invocations, so a hot instance reads the table at most once
// a minute rather than once per request. An admin edit therefore takes effect
// within ~a minute (or immediately on a cold instance) — fine for config, and
// far cheaper than a query per call.
//
// SECRETS DO NOT BELONG HERE. Provider API keys, webhook secrets and the PIN
// pepper stay in env vars: app_settings is readable by the admin console.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CACHE_TTL_MS = 60_000;

let cache: Record<string, unknown> | null = null;
let cachedAt = 0;
let inFlight: Promise<Record<string, unknown>> | null = null;

function client() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
}

async function load(): Promise<Record<string, unknown>> {
  const now = Date.now();
  if (cache && now - cachedAt < CACHE_TTL_MS) return cache;
  // Collapse concurrent misses into one query.
  if (inFlight) return inFlight;

  inFlight = (async () => {
    try {
      const { data, error } = await client().from("app_settings").select("key, value");
      if (error) throw error;
      const map: Record<string, unknown> = {};
      for (const row of data ?? []) map[(row as any).key] = (row as any).value;
      cache = map;
      cachedAt = Date.now();
      return map;
    } catch (e) {
      // Never let a settings failure break a money path — fall through to
      // env/defaults and retry on the next call.
      console.error("settings: load failed, using env/defaults:", e);
      return cache ?? {};
    } finally {
      inFlight = null;
    }
  })();
  return inFlight;
}

/** Numeric setting: app_settings -> env var -> fallback. */
export async function getNumber(key: string, envKey: string, fallback: number): Promise<number> {
  const settings = await load();
  const raw = settings[key];
  const n = typeof raw === "number" ? raw : Number(raw);
  if (Number.isFinite(n)) return n;
  const env = Number(Deno.env.get(envKey));
  return Number.isFinite(env) ? env : fallback;
}

/** Boolean setting: app_settings -> env var ("true"/"1") -> fallback. */
export async function getBool(key: string, envKey: string, fallback: boolean): Promise<boolean> {
  const settings = await load();
  const raw = settings[key];
  if (typeof raw === "boolean") return raw;
  if (raw === "true" || raw === "false") return raw === "true";
  const env = (Deno.env.get(envKey) ?? "").toLowerCase();
  if (env === "true" || env === "1") return true;
  if (env === "false" || env === "0") return false;
  return fallback;
}

/** String setting: app_settings -> env var -> fallback. */
export async function getString(key: string, envKey: string, fallback: string): Promise<string> {
  const settings = await load();
  const raw = settings[key];
  if (typeof raw === "string" && raw.length > 0) return raw;
  const env = Deno.env.get(envKey);
  return env && env.length > 0 ? env : fallback;
}

/** Drop the cache — used by admin-update-setting so an edit applies at once. */
export function invalidateSettingsCache() {
  cache = null;
  cachedAt = 0;
}
