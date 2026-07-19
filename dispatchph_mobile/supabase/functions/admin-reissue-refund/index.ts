import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { flwTransfer } from "../_shared/flutterwave.ts";
import { logAdminAction } from "../_shared/audit.ts";

// Re-send a bank refund that Flutterwave failed to pay.
//
// A refund can be accepted by Flutterwave and still not settle: the commonest
// cause is a payout balance that cannot cover it. When that happens the order
// already reads 'refunded' and the refund request already reads 'approved', so
// no existing screen will act on it again. Without this function the buyer is
// owed money the system believes it has already sent, and there is no way to
// pay them except by hand.
//
// Every guard here exists to stop the opposite mistake, paying twice:
//
//   - only a transaction already marked 'failed' can be re-sent, so a refund
//     still in flight cannot be duplicated by an impatient operator
//   - the row is claimed atomically out of 'failed', so two administrators
//     cannot both re-send it
//   - a fresh reference is used, because Flutterwave rejects a repeated one,
//     and the attempt number is carried in it so the history stays readable
//   - if the new transfer is refused the row goes back to 'failed' rather than
//     being left in a state nothing will retry

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
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    if (!callerId) return json({ error: "Unauthorized" }, 401);
    const { data: caller } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
    if (caller?.role !== "admin") return json({ error: "Admin only" }, 403);

    const { order_id, reason } = await req.json();
    if (!order_id) return json({ error: "order_id is required" }, 400);
    if (!reason || String(reason).trim().length < 5) {
      return json({ error: "A reason is required — it is recorded against your name." }, 400);
    }

    // Every refund transaction for this order, newest first.
    const { data: txns } = await supabase
      .from("transactions")
      .select("id, order_id, buyer_id, amount, status, paystack_reference, created_at")
      .eq("order_id", order_id)
      .eq("type", "refund")
      .order("created_at", { ascending: false });

    if (!txns || txns.length === 0) return json({ error: "No refund exists for this order." }, 404);

    // If ANY attempt succeeded, the buyer has their money. Refuse.
    if (txns.some((t: any) => t.status === "success")) {
      return json({ error: "This refund has already been paid.", code: "already_paid" }, 409);
    }
    if (txns.some((t: any) => t.status === "processing")) {
      return json({
        error: "A refund for this order is still in flight. Wait for it to settle or fail before re-sending.",
        code: "in_flight",
      }, 409);
    }

    const latest: any = txns[0];
    if (latest.status !== "failed") {
      return json({ error: `Cannot re-send a refund in state '${latest.status}'.`, code: "bad_state" }, 409);
    }

    const { data: buyerBank } = await supabase
      .from("buyer_bank_accounts")
      .select("bank_code, account_number, is_verified")
      .eq("buyer_id", latest.buyer_id)
      .maybeSingle();
    if (!buyerBank?.is_verified || !buyerBank?.bank_code || !buyerBank?.account_number) {
      return json({
        error: "The buyer has no verified bank account on file, so there is nowhere to send this.",
        code: "no_bank_account",
      }, 400);
    }

    // Claim it, so a second administrator cannot start a parallel transfer.
    const { data: claimed } = await supabase
      .from("transactions")
      .update({ status: "processing" })
      .eq("id", latest.id)
      .eq("status", "failed")
      .select("id")
      .maybeSingle();
    if (!claimed) {
      return json({ error: "Someone else is already re-sending this refund.", code: "claim_lost" }, 409);
    }

    // Flutterwave rejects a reused reference, so number the attempts. Base is
    // 38 chars and the suffix keeps it inside the 42-character limit.
    const attempt = txns.length + 1;
    const ref = `refund${String(order_id).replace(/-/g, "")}r${attempt}`;
    const amount = Number(latest.amount) || 0;

    let transfer: { ok: boolean; status: number; data: any };
    try {
      transfer = await flwTransfer(
        {
          action: "instant",
          type: "bank",
          payload: {
            destination_currency: "NGN",
            amount: { applies_to: "destination_currency", value: amount },
            recipient: {
              bank: { account_number: buyerBank.account_number, code: buyerBank.bank_code },
            },
          },
        },
        ref,
      );
    } catch (e) {
      await supabase.from("transactions").update({ status: "failed" }).eq("id", latest.id);
      console.error(`reissue refund threw for ${ref}:`, e);
      return json({ error: "Could not reach the transfer service. The refund is still unpaid." }, 502);
    }

    const tData = transfer.data?.data ?? transfer.data;
    if (!transfer.ok) {
      await supabase.from("transactions").update({ status: "failed" }).eq("id", latest.id);
      console.error(`reissue refund failed status=${transfer.status} body=${JSON.stringify(transfer.data).slice(0, 300)}`);
      return json({ error: tData?.message || "Flutterwave refused the transfer. The refund is still unpaid." }, 502);
    }

    // Accepted. It stays 'processing' until the disburse webhook says otherwise.
    await supabase
      .from("transactions")
      .update({ paystack_reference: ref })
      .eq("id", latest.id);

    // Close the exception that brought this to the operator's attention.
    await supabase
      .from("reconciliation_exceptions")
      .update({
        status: "resolved",
        resolved_by: callerId,
        resolved_at: new Date().toISOString(),
        resolution_note: `Refund re-sent as ${ref}. ${reason}`,
      })
      .eq("kind", "refund_transfer_failed")
      .eq("target_id", String(order_id))
      .eq("status", "open");

    await logAdminAction({
      adminId: callerId,
      action: "refund_reissued",
      targetType: "order",
      targetId: String(order_id),
      summary: `Re-sent a failed ₦${amount.toLocaleString()} refund on order ${String(order_id).slice(0, 8)}`,
      metadata: {
        reason,
        amount,
        attempt,
        previous_reference: latest.paystack_reference,
        new_reference: ref,
        buyer_id: latest.buyer_id,
      },
    });

    return json({
      success: true,
      message: "Refund re-sent. It stays in flight until Flutterwave confirms it reached the bank.",
      reference: ref,
    });
  } catch (error: any) {
    console.error("admin-reissue-refund error:", error);
    return json({ error: error.message }, 500);
  }
});
