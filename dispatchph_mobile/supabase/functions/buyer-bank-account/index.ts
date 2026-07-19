import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { flwGet, flwPost } from "../_shared/flutterwave.ts";

// Buyer bank account: list banks, resolve the account name, and save it.
//
// This is the destination for refunds — a buyer must have a verified account on
// file before a refund can be requested, since refunds are paid out to the bank
// rather than to a platform balance.
//
// Migrated from Paystack to Flutterwave: account resolution now uses
// POST /banks/account-resolve, and the Paystack "transfer recipient" step is
// gone entirely — flwTransfer pays an account number + bank code directly, so
// there is no recipient object to create or keep in sync.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

function getUserIdFromToken(authHeader: string | null): string | null {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return null;
  const token = authHeader.replace("Bearer ", "");
  if (!token || token === supabaseAnonKey) return null;
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const payload = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
    if (payload.exp && payload.exp < Math.floor(Date.now() / 1000)) return null;
    return payload.sub || null;
  } catch {
    return null;
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const callerId = getUserIdFromToken(req.headers.get("Authorization"));

    // Read the body ONCE. The previous version called req.json() again inside
    // the save branch, which throws "Body already consumed" — so saving a bank
    // account could never succeed.
    const body = await req.json().catch(() => ({}));
    const { action, buyer_id, bank_code, account_number, account_name, bank_name } = body as Record<string, string>;

    // Listing banks needs no buyer context.
    if (action === "banks") {
      if (!callerId) return json({ error: "Unauthorized" }, 401);
      const res = await flwGet("/banks?country=NG");
      const list = (res.data?.data ?? res.data) as any;
      if (!res.ok || !Array.isArray(list)) {
        console.error("banks list failed:", res.status, JSON.stringify(res.data).slice(0, 200));
        return json({ error: "Could not load the bank list. Please try again." }, 502);
      }
      // Normalise to { code, name } for the picker.
      const banks = list
        .map((b: any) => ({ code: String(b.code ?? b.bank_code ?? ""), name: String(b.name ?? b.bank_name ?? "") }))
        .filter((b: any) => b.code && b.name);
      return json({ success: true, banks });
    }

    if (!buyer_id) return json({ error: "Missing buyer_id" }, 400);
    if (!callerId || callerId !== buyer_id) {
      return json({ error: "Authenticated user does not match buyer_id" }, 403);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // ── Resolve the account name so the buyer can confirm it before saving ──
    if (action === "verify") {
      if (!account_number || !bank_code) return json({ error: "Missing account_number or bank_code" }, 400);
      if (!/^\d{10}$/.test(String(account_number))) {
        return json({ error: "Account number must be 10 digits." }, 400);
      }

      const res = await flwPost(
        "/banks/account-resolve",
        { currency: "NGN", account: { code: String(bank_code), number: String(account_number) } },
        `resolve-${buyer_id}-${account_number}`,
      );
      const d = (res.data?.data ?? res.data) as any;
      const resolvedName = d?.account_name;
      if (!res.ok || !resolvedName) {
        console.error("account-resolve failed:", res.status, JSON.stringify(res.data).slice(0, 200));
        return json(
          { error: (res.data as any)?.message || "We couldn't confirm that account. Check the number and bank." },
          400,
        );
      }
      return json({
        success: true,
        account_name: resolvedName,
        account_number: d?.account_number ?? account_number,
      });
    }

    // ── Save the (already resolved) account ────────────────────────────────
    if (action === "save") {
      if (!account_number || !bank_code || !account_name || !bank_name) {
        return json({ error: "Missing required fields" }, 400);
      }

      const { error: saveError } = await supabase.from("buyer_bank_accounts").upsert(
        {
          buyer_id,
          bank_name,
          bank_code,
          account_number,
          account_name,
          is_verified: true,
        },
        { onConflict: "buyer_id" },
      );
      if (saveError) {
        console.error("Save bank error:", saveError);
        return json({ error: "Failed to save bank account" }, 500);
      }
      return json({ success: true, message: "Bank account saved" });
    }

    if (action === "get") {
      const { data: bank } = await supabase
        .from("buyer_bank_accounts")
        .select("id, bank_name, bank_code, account_number, account_name, is_verified")
        .eq("buyer_id", buyer_id)
        .maybeSingle();
      return json({ success: true, bank });
    }

    return json({ error: "Invalid action" }, 400);
  } catch (error: any) {
    console.error("buyer-bank-account error:", error);
    return json({ error: error.message }, 500);
  }
});
