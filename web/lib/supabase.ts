import { createClient, type SupabaseClient } from "@supabase/supabase-js";

// Server-only Supabase client for the public product/store pages.
//
// Uses the service-role key, which is safe here because these pages are
// server-rendered (the key never reaches the browser) and the code only runs
// fixed, parameterized read queries on public product/store data. This avoids
// depending on table RLS allowing the anonymous role.
//
// Created lazily (not at module load) so `next build` can collect page data
// without the env vars being present — they're only needed at request time.
let client: SupabaseClient | null = null;

export function getSupabase(): SupabaseClient {
  if (client) return client;
  const url = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceKey) {
    throw new Error(
      "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set",
    );
  }
  client = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return client;
}
