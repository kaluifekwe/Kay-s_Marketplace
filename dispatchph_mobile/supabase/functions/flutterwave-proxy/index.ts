import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { getFlwToken, flwUrl, flwPost } from "../_shared/flutterwave.ts";

// Bank helpers backed by Flutterwave v4 (so bank list + name resolution use the
// same provider as payouts — no Paystack dependency). Actions:
//   list-banks       -> GET  /banks?country=NG
//   resolve-account  -> POST /banks/account-resolve
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function isAuthed(authHeader: string | null): boolean {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return false;
  const token = authHeader.replace("Bearer ", "");
  return !!token && token !== supabaseAnonKey;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    if (!isAuthed(req.headers.get("Authorization"))) return json({ error: "Unauthorized" }, 401);

    const { action, account_number, bank_code } = await req.json();

    if (action === "list-banks") {
      const token = await getFlwToken();
      const res = await fetch(flwUrl("/banks?country=NG"), {
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        console.error("flw list-banks error:", JSON.stringify(data));
        return json({ error: "Failed to load banks" }, 400);
      }
      const banks = (data.data ?? []).map((b: any) => ({ code: b.code, name: b.name }));
      return json({ banks });
    }

    if (action === "resolve-account") {
      if (!account_number || !bank_code) return json({ error: "Missing account_number or bank_code" }, 400);
      const resolve = await flwPost(
        "/banks/account-resolve",
        { account: { code: String(bank_code), number: String(account_number) }, currency: "NGN" },
        `resolve_${bank_code}_${account_number}`
      );
      const acctName = resolve.data?.data?.account_name ?? resolve.data?.account_name;
      if (!resolve.ok || !acctName) {
        console.error(`flw resolve error: status=${resolve.status} body=${JSON.stringify(resolve.data)}`);
        return json({ error: resolve.data?.message || "Cannot resolve account" }, 400);
      }
      return json({ account_name: acctName });
    }

    return json({ error: "Unknown action" }, 400);
  } catch (error: any) {
    console.error("flutterwave-proxy error:", error);
    return json({ error: error.message }, 500);
  }
});
