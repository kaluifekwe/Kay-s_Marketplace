import { createClient } from "@refinedev/supabase";

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string;
const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY as string;

if (!SUPABASE_URL || !SUPABASE_KEY || SUPABASE_KEY.startsWith("PASTE_")) {
  // Fail loud in the console so a missing/placeholder key is obvious in dev.
  // eslint-disable-next-line no-console
  console.warn(
    "[dispatch-admin] VITE_SUPABASE_ANON_KEY is not set. Paste your project's public anon key into .env",
  );
}

// The anon key is the PUBLIC key — safe in the browser. Row-Level Security plus
// the admin-role gate in authProvider are what actually protect the data.
export const supabaseClient = createClient(SUPABASE_URL, SUPABASE_KEY, {
  db: { schema: "public" },
  auth: { persistSession: true, autoRefreshToken: true },
});
