import { createClient, type SupabaseClient } from "@supabase/supabase-js";

// Server-only Supabase client for the public storefront.
//
// SECURITY: this uses the ANON key only, and the code reads ONLY the
// web_public_* views (see web_public_views.sql). There is no service-role key
// in this project on purpose: if this app were ever compromised, the attacker
// gets nothing a stranger could not already see. Do not add a service key here.
//
// Created lazily so `next build` works without env vars; they are only needed
// at request time.
let client: SupabaseClient | null = null;

// Upstream responses are cached for 5 minutes so a traffic spike (or a scraper)
// hits the CDN/cache instead of the database.
const REVALIDATE_SECONDS = 300;

export function getSupabase(): SupabaseClient {
  if (client) return client;
  const url = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  if (!url || !anonKey) {
    throw new Error("SUPABASE_URL and SUPABASE_ANON_KEY must be set");
  }
  client = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input, init) =>
        fetch(input, { ...init, next: { revalidate: REVALIDATE_SECONDS } }),
    },
  });
  return client;
}

/** Host of the Supabase project, used to allowlist image URLs. */
export function supabaseHost(): string {
  try {
    return new URL(process.env.SUPABASE_URL ?? "").host;
  } catch {
    return "";
  }
}
