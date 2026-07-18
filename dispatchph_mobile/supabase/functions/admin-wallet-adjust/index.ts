import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Admin manual wallet adjustment — a goodwill credit or a correction debit on a
// buyer/vendor wallet. Routes through the service-role-only wallet_credit /
// wallet_debit RPCs (atomic, idempotent, no-overdraw), so the balance is only
// ever moved through the audited money path — never a raw table write. Gated on
// role='admin'; every adjustment records the admin id + reason in the ledger
// row's metadata for audit.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
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
    if (!callerId) return json({ error: "Unauthorized" }, 401);

    const { user_id, amount, direction, reason } = await req.json();
    if (!user_id) return json({ error: "Missing user_id" }, 400);
    if (direction !== "credit" && direction !== "debit") {
      return json({ error: "direction must be 'credit' or 'debit'" }, 400);
    }
    const amt = Math.round((Number(amount) + Number.EPSILON) * 100) / 100;
    if (!Number.isFinite(amt) || amt <= 0) {
      return json({ error: "Amount must be a positive number" }, 400);
    }
    if (!(reason && String(reason).trim())) {
      return json({ error: "A reason is required for every adjustment" }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: caller } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
    if (caller?.role !== "admin") return json({ error: "Admin only" }, 403);

    const { data: target } = await supabase.from("users").select("id").eq("id", user_id).maybeSingle();
    if (!target) return json({ error: "User not found" }, 404);

    const reference = `adj_${crypto.randomUUID()}`;
    const description = `Admin ${direction}: ${String(reason).trim().slice(0, 200)}`;
    const metadata = { admin_id: callerId, reason: String(reason).trim(), source: "admin_panel" };

    if (direction === "credit") {
      const { data: balance, error } = await supabase.rpc("wallet_credit", {
        p_user_id: user_id,
        p_amount: amt,
        p_type: "adjustment",
        p_reference: reference,
        p_description: description,
        p_metadata: metadata,
      });
      if (error) {
        console.error("admin-wallet-adjust credit error:", error);
        return json({ error: error.message || "Credit failed" }, 500);
      }
      return json({ success: true, direction, amount: amt, balance: Number(balance) });
    }

    // Debit: wallet_debit returns the new balance, or NULL on insufficient funds
    // (no row mutated, reservation rolled back — safe to retry after a top-up).
    const { data: balance, error } = await supabase.rpc("wallet_debit", {
      p_user_id: user_id,
      p_amount: amt,
      p_type: "adjustment",
      p_reference: reference,
      p_description: description,
      p_metadata: metadata,
    });
    if (error) {
      console.error("admin-wallet-adjust debit error:", error);
      return json({ error: error.message || "Debit failed" }, 500);
    }
    if (balance === null || balance === undefined) {
      return json({ error: "insufficient_balance", message: "The wallet balance is too low for this debit." }, 400);
    }
    return json({ success: true, direction, amount: amt, balance: Number(balance) });
  } catch (error: any) {
    console.error("admin-wallet-adjust error:", error);
    return json({ error: error.message }, 500);
  }
});
