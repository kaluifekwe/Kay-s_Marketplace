import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { flwTransfer } from "../_shared/flutterwave.ts";
import { logAdminAction } from "../_shared/audit.ts";

// Maker-checker for large payouts. wallet-withdraw parks anything at or above
// withdrawal_approval_threshold as `pending_approval` — the wallet is already
// debited (the funds are reserved) but no transfer has been initiated.
//
//   approve → fire the Flutterwave transfer; the disburse webhook finalises it
//   reject  → reverse the hold back into the wallet, so the vendor keeps the money
//
// The row is claimed atomically out of `pending_approval`, so two administrators
// cannot both release the same payout. If the transfer itself fails, the hold is
// reversed rather than leaving the vendor debited with nothing sent.

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

async function notify(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  title: string,
  body: string,
) {
  try {
    await supabase.from("notifications").insert({ user_id: userId, title, body, type: "general" });
    const { data: tok } = await supabase
      .from("device_tokens").select("fcm_token").eq("user_id", userId).maybeSingle();
    if (tok?.fcm_token) {
      await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ user_id: userId, title, body, data: { type: "withdrawal" } }),
      });
    }
  } catch (_) { /* best-effort */ }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    if (!callerId) return json({ error: "Unauthorized" }, 401);

    const { withdrawal_id, decision, notes } = await req.json();
    if (!withdrawal_id) return json({ error: "Missing withdrawal_id" }, 400);
    if (decision !== "approve" && decision !== "reject") {
      return json({ error: "decision must be 'approve' or 'reject'" }, 400);
    }
    if (decision === "reject" && !(notes && String(notes).trim())) {
      return json({ error: "A reason is required to reject a payout" }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: caller } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
    if (caller?.role !== "admin") return json({ error: "Admin only" }, 403);

    const { data: wd } = await supabase
      .from("withdrawals")
      .select("id, user_id, amount, status, bank_name, bank_code, account_number, flw_reference")
      .eq("id", withdrawal_id)
      .maybeSingle();
    if (!wd) return json({ error: "Withdrawal not found" }, 404);
    if (wd.status !== "pending_approval") {
      return json({ success: true, state: wd.status, message: `This payout is not awaiting approval (it is "${wd.status}").` });
    }

    const amount = Number(wd.amount) || 0;
    const ref = (wd.flw_reference as string) || `wd${String(wd.id).replace(/-/g, "")}`;

    // ── REJECT: give the money back, nothing leaves ─────────────────────────
    if (decision === "reject") {
      const { data: claimed } = await supabase
        .from("withdrawals")
        .update({ status: "failed", failure_reason: `rejected_by_admin: ${notes}` })
        .eq("id", withdrawal_id)
        .eq("status", "pending_approval")
        .select("id");
      if (!claimed || claimed.length === 0) {
        return json({ success: true, message: "This payout has already been decided." });
      }

      const { error: revErr } = await supabase.rpc("wallet_credit", {
        p_user_id: wd.user_id,
        p_amount: amount,
        p_type: "reversal",
        p_reference: `rev_${ref}`,
        p_description: "Withdrawal reversal (payout declined)",
      });
      if (revErr) {
        console.error(`CRITICAL: reversal failed for ${ref} — wallet left short:`, revErr);
        return json({ error: "Could not return the funds to the wallet. Check logs before retrying." }, 500);
      }
      await supabase.from("wallet_transactions").update({ status: "failed" }).eq("reference", ref);

      await notify(
        supabase, wd.user_id, "Withdrawal declined",
        `Your ₦${amount.toLocaleString()} withdrawal was declined and the amount is back in your wallet. Reason: ${notes}`,
      );
      await logAdminAction({
        adminId: callerId, action: "withdrawal.reject", targetType: "withdrawal", targetId: String(wd.id),
        summary: `Declined a ₦${amount.toLocaleString()} payout — ${notes}`,
        metadata: { amount, user_id: wd.user_id, notes },
      });
      return json({ success: true, decision: "rejected" });
    }

    // ── APPROVE: claim, then send ───────────────────────────────────────────
    const { data: claimed } = await supabase
      .from("withdrawals")
      .update({ status: "processing" })
      .eq("id", withdrawal_id)
      .eq("status", "pending_approval")
      .select("id");
    if (!claimed || claimed.length === 0) {
      return json({ success: true, message: "This payout has already been decided." });
    }

    let transfer: { ok: boolean; status: number; data: any };
    try {
      transfer = await flwTransfer(
        {
          action: "instant",
          type: "bank",
          reference: ref,
          narration: "Kays Market payout",
          payment_instruction: {
            source_currency: "NGN",
            destination_currency: "NGN",
            amount: { applies_to: "destination_currency", value: amount },
            recipient: { bank: { account_number: wd.account_number, code: wd.bank_code } },
          },
        },
        ref,
      );
    } catch (e) {
      console.error(`approve-withdrawal: transfer threw for ${ref}:`, e);
      await supabase.from("withdrawals").update({ status: "pending_approval" }).eq("id", withdrawal_id);
      return json({ error: "Could not reach the transfer service. The payout stays awaiting approval." }, 502);
    }

    const tData = transfer.data?.data ?? transfer.data;
    if (!transfer.ok) {
      // Transfer never left — reverse the hold and fail it, mirroring wallet-withdraw.
      console.error(`approve-withdrawal: transfer rejected status=${transfer.status} body=${JSON.stringify(transfer.data).slice(0, 300)}`);
      const { error: revErr } = await supabase.rpc("wallet_credit", {
        p_user_id: wd.user_id,
        p_amount: amount,
        p_type: "reversal",
        p_reference: `rev_${ref}`,
        p_description: "Withdrawal reversal (transfer not completed)",
      });
      if (revErr) console.error(`CRITICAL: reversal failed for ${ref}:`, revErr);
      await supabase.from("wallet_transactions").update({ status: "failed" }).eq("reference", ref);
      await supabase
        .from("withdrawals")
        .update({ status: "failed", failure_reason: tData?.message || "transfer_rejected" })
        .eq("id", withdrawal_id);
      return json({ error: tData?.message || "Transfer could not be initiated. The amount was returned to the wallet." }, 400);
    }

    await supabase
      .from("withdrawals")
      .update({ flw_transfer_id: String(tData?.id ?? ""), flw_reference: ref })
      .eq("id", withdrawal_id);

    await notify(
      supabase, wd.user_id, "Withdrawal approved",
      `Your ₦${amount.toLocaleString()} withdrawal was approved and is on its way to your bank.`,
    );
    await logAdminAction({
      adminId: callerId, action: "withdrawal.approve", targetType: "withdrawal", targetId: String(wd.id),
      summary: `Approved a ₦${amount.toLocaleString()} payout to ${wd.bank_name ?? "the vendor's bank"}`,
      metadata: { amount, user_id: wd.user_id, notes: notes ?? null },
    });

    return json({ success: true, decision: "approved", status: "processing" });
  } catch (error: any) {
    console.error("admin-approve-withdrawal error:", error);
    return json({ error: error.message }, 500);
  }
});
