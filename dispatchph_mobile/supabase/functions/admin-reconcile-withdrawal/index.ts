import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logAdminAction } from "../_shared/audit.ts";
import { flwGet } from "../_shared/flutterwave.ts";

// Admin reconciliation for a withdrawal stuck in `processing` — i.e. the payout
// fired but the transfer.disburse webhook never arrived, so the row never
// finalized. We ask Flutterwave for the transfer's REAL status and apply the
// exact same finalize logic the webhook uses:
//   SUCCESSFUL → mark success (money already left; the up-front debit stands).
//   FAILED     → reverse the hold back into the wallet + mark failed.
//   still pending → leave it; report back so the admin retries later.
//
// This is the SAFE alternative to a blind "retry": re-initiating a transfer that
// actually succeeded would double-pay the vendor. Everything is idempotent (a
// row already success/failed is a no-op) and gated on role='admin', run as the
// service role. Requires the payout relay to proxy GET (see payout-relay).

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

const SUCCESS = ["successful", "succeeded", "success", "completed", "complete", "paid"];
const FAILED = ["failed", "reversed", "cancelled", "canceled", "declined", "error"];

async function notify(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  title: string,
  body: string,
) {
  try {
    await supabase.from("notifications").insert({ user_id: userId, title, body, type: "general" });
    const { data: tok } = await supabase
      .from("device_tokens")
      .select("fcm_token")
      .eq("user_id", userId)
      .maybeSingle();
    if (tok?.fcm_token) {
      await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ user_id: userId, title, body, data: { type: "withdrawal" } }),
      });
    }
  } catch (_) {
    /* best-effort */
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    if (!callerId) return json({ error: "Unauthorized" }, 401);

    const { withdrawal_id } = await req.json();
    if (!withdrawal_id) return json({ error: "Missing withdrawal_id" }, 400);

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: caller } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
    if (caller?.role !== "admin") return json({ error: "Admin only" }, 403);

    const { data: wd } = await supabase
      .from("withdrawals")
      .select("id, user_id, amount, status, flw_transfer_id, flw_reference")
      .eq("id", withdrawal_id)
      .maybeSingle();
    if (!wd) return json({ error: "Withdrawal not found" }, 404);

    // Only an in-flight transfer can be reconciled. Terminal rows are done; a
    // `pending` row never fired a transfer (nothing at Flutterwave to check).
    if (wd.status !== "processing") {
      return json({ success: true, state: wd.status, message: `Nothing to reconcile — status is "${wd.status}".` });
    }
    if (!wd.flw_transfer_id && !wd.flw_reference) {
      return json({ error: "This withdrawal has no transfer reference to look up." }, 400);
    }

    // Ask Flutterwave for the transfer's real status.
    const lookup = wd.flw_transfer_id
      ? `/direct-transfers/${wd.flw_transfer_id}`
      : `/direct-transfers?reference=${encodeURIComponent(wd.flw_reference)}`;
    const res = await flwGet(lookup);
    if (!res.ok) {
      console.error(`reconcile: FLW lookup failed status=${res.status} body=${JSON.stringify(res.data)}`);
      return json(
        { error: "Could not reach Flutterwave to check this transfer. Try again shortly." },
        502,
      );
    }

    // The transfer object sits at data.data (list endpoint returns an array).
    const obj = Array.isArray(res.data?.data) ? res.data.data[0] : (res.data?.data ?? res.data);
    const flwStatus = String(obj?.status ?? "").toLowerCase();
    const amount = Number(wd.amount) || 0;
    const reference = wd.flw_reference as string;

    if (SUCCESS.includes(flwStatus)) {
      await supabase.from("withdrawals").update({ status: "success" }).eq("id", wd.id);
      await notify(supabase, wd.user_id, "Withdrawal sent", `₦${amount.toLocaleString()} was sent to your bank.`);
      await logAdminAction({
        adminId: callerId, action: "withdrawal.reconcile", targetType: "withdrawal", targetId: wd.id,
        summary: `Reconciled a ₦${amount.toLocaleString()} withdrawal — confirmed sent`,
        metadata: { outcome: "success", amount, flw_status: flwStatus, user_id: wd.user_id },
      });
      return json({ success: true, state: "success", flw_status: flwStatus });
    }

    if (FAILED.includes(flwStatus)) {
      // Reverse the hold back into the wallet (idempotent on rev_<ref>), mark the
      // debit ledger row failed, then fail the withdrawal — mirrors the webhook.
      const { error: revErr } = await supabase.rpc("wallet_credit", {
        p_user_id: wd.user_id,
        p_amount: amount,
        p_type: "reversal",
        p_reference: `rev_${reference}`,
        p_description: "Withdrawal reversal (transfer failed)",
      });
      if (revErr) {
        console.error(`reconcile: reversal failed for ${reference} — wallet left short:`, revErr);
        return json({ error: "Refund-to-wallet reversal failed. Do not retry; check logs." }, 500);
      }
      await supabase.from("wallet_transactions").update({ status: "failed" }).eq("reference", reference);
      await supabase
        .from("withdrawals")
        .update({ status: "failed", failure_reason: "transfer_failed_reconciled" })
        .eq("id", wd.id);
      await notify(
        supabase,
        wd.user_id,
        "Withdrawal failed",
        `Your ₦${amount.toLocaleString()} withdrawal failed and was returned to your wallet.`,
      );
      await logAdminAction({
        adminId: callerId, action: "withdrawal.reconcile", targetType: "withdrawal", targetId: wd.id,
        summary: `Reconciled a ₦${amount.toLocaleString()} withdrawal — transfer failed, money returned to wallet`,
        metadata: { outcome: "failed", amount, flw_status: flwStatus, user_id: wd.user_id },
      });
      return json({ success: true, state: "failed", flw_status: flwStatus });
    }

    // Still in progress at Flutterwave — leave it be.
    return json({
      success: true,
      state: "still_processing",
      flw_status: flwStatus || "unknown",
      message: "Flutterwave still reports this transfer as in progress. Try again later.",
    });
  } catch (error: any) {
    console.error("admin-reconcile-withdrawal error:", error);
    return json({ error: error.message }, 500);
  }
});
