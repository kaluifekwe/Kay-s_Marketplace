import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Account + data deletion (Google Play requirement for apps with sign-up).
// The caller deletes THEIR OWN account (we act on auth.uid()). We first block
// deletion while money is still in play (a positive wallet balance), then remove
// the user's data and finally the auth login. Most app tables reference
// users(id) ON DELETE CASCADE, so deleting the users row clears them; we also
// best-effort delete wallet rows explicitly in case any aren't cascaded.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

function callerId(authHeader: string | null): string | null {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return null;
  const token = authHeader.replace("Bearer ", "");
  if (!token || token === supabaseAnonKey) return null;
  try {
    const p = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    if (p.exp && p.exp < Math.floor(Date.now() / 1000)) return null;
    return p.sub || null;
  } catch {
    return null;
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const uid = callerId(req.headers.get("Authorization"));
    if (!uid) return json({ error: "Unauthorized" }, 401);

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Guard: don't delete while there's money in the wallet — the user should
    // withdraw it first (otherwise it's lost).
    const { data: wallet } = await supabase
      .from("wallets")
      .select("balance")
      .eq("user_id", uid)
      .maybeSingle();
    if (wallet && Number(wallet.balance) > 0) {
      return json({
        error: "wallet_not_empty",
        message: "Withdraw your wallet balance to your bank before deleting your account.",
      }, 409);
    }

    // Best-effort cleanup of the user's rows. Each is wrapped so a missing table
    // or already-cascaded row can't abort the deletion.
    const del = async (table: string, col: string) => {
      try {
        await supabase.from(table).delete().eq(col, uid);
      } catch (_) {
        // ignore — table may not exist or rows already cascaded
      }
    };
    await del("withdrawal_pins", "user_id");
    await del("wallet_transactions", "user_id");
    await del("withdrawals", "user_id");
    await del("wallets", "user_id");
    await del("vendor_bank_accounts", "user_id");
    await del("buyer_bank_accounts", "buyer_id");
    await del("cart_items", "buyer_id");

    // Deleting the users row cascades to the rest (stores → products, etc.).
    try {
      await supabase.from("users").delete().eq("id", uid);
    } catch (e) {
      console.error("delete-account users delete error:", e);
    }

    // Finally remove the auth login so the account is truly gone.
    const { error: authErr } = await supabase.auth.admin.deleteUser(uid);
    if (authErr) {
      console.error("delete-account admin.deleteUser error:", authErr);
      return json({
        error: "delete_failed",
        message: "We couldn't fully delete your account. Please contact support.",
      }, 500);
    }

    return json({ success: true });
  } catch (e: any) {
    console.error("delete-account error:", e);
    return json({ error: "delete_failed", message: "We couldn't delete your account. Please try again." }, 500);
  }
});
