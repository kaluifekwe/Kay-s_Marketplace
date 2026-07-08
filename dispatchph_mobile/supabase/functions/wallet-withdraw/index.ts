import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { flwTransfer } from "../_shared/flutterwave.ts";

// Withdraw wallet balance to the user's bank via a Flutterwave v4 direct
// transfer. Vendors can withdraw their whole balance; buyers can only withdraw
// REFUNDED money (enforced by the wallet_withdrawable RPC). The wallet is
// debited up-front as a hold; the transfer.disburse webhook confirms success or
// reverses on failure.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

const MIN_WITHDRAWAL = 100;

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

    const { amount } = await req.json();
    const amt = Number(amount);
    if (!amt || amt < MIN_WITHDRAWAL) {
      return json({ error: `Minimum withdrawal is ₦${MIN_WITHDRAWAL}.` }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: user } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
    const role = user?.role ?? "buyer";

    // How much this user may withdraw (vendor=full, buyer=refunds only).
    const { data: withdrawable, error: wErr } = await supabase.rpc("wallet_withdrawable", { p_user_id: callerId });
    if (wErr) {
      console.error("wallet_withdrawable error:", wErr);
      return json({ error: "Could not check withdrawable balance" }, 500);
    }
    const cap = Number(withdrawable) || 0;
    if (amt > cap) {
      return json({
        error: "exceeds_withdrawable",
        message: role === "vendor"
          ? "Amount exceeds your wallet balance."
          : "You can only withdraw refunded money. This exceeds your withdrawable amount.",
        withdrawable: cap,
      }, 400);
    }

    // Destination bank account (vendors -> vendor_bank_accounts, buyers -> buyer_bank_accounts).
    const bankTable = role === "vendor" ? "vendor_bank_accounts" : "buyer_bank_accounts";
    const idCol = role === "vendor" ? "user_id" : "buyer_id";
    const { data: bank } = await supabase
      .from(bankTable)
      .select("bank_name, bank_code, account_number, account_name")
      .eq(idCol, callerId)
      .maybeSingle();
    if (!bank || !bank.account_number || !bank.bank_code) {
      return json({ error: "no_bank_account", message: "Add a bank account before withdrawing." }, 400);
    }

    // 1) Create the withdrawal record (pending) with a bank snapshot.
    const { data: wd, error: wdErr } = await supabase
      .from("withdrawals")
      .insert({
        user_id: callerId,
        amount: amt,
        bank_name: bank.bank_name,
        account_number: bank.account_number,
        account_name: bank.account_name,
        bank_code: bank.bank_code,
        status: "pending",
      })
      .select("id")
      .maybeSingle();
    if (wdErr || !wd) {
      console.error("withdrawal insert error:", wdErr);
      return json({ error: "Could not create withdrawal" }, 500);
    }
    const withdrawalId = wd.id as string;
    const ref = `wd${withdrawalId.replace(/-/g, "")}`;

    // 2) Debit the wallet as a hold (idempotent on the withdrawal reference).
    const { data: newBalance, error: debitErr } = await supabase.rpc("wallet_debit", {
      p_user_id: callerId,
      p_amount: amt,
      p_type: "withdrawal",
      p_reference: ref,
      p_description: "Withdrawal to bank",
      p_metadata: { withdrawal_id: withdrawalId },
    });
    if (debitErr) {
      await supabase.from("withdrawals").update({ status: "failed", failure_reason: "debit_error" }).eq("id", withdrawalId);
      console.error("wallet_debit error:", debitErr);
      return json({ error: "Wallet debit failed" }, 500);
    }
    if (newBalance === null) {
      await supabase.from("withdrawals").update({ status: "failed", failure_reason: "insufficient" }).eq("id", withdrawalId);
      return json({ error: "insufficient_balance", message: "Your wallet balance is too low." }, 402);
    }

    // 3) Initiate the Flutterwave v4 bank transfer (routed through the static-IP
    // relay so Flutterwave sees a whitelisted IP).
    const transfer = await flwTransfer(
      {
        action: "instant",
        type: "bank",
        reference: ref,
        payment_instruction: {
          source_currency: "NGN",
          destination_currency: "NGN",
          amount: { applies_to: "destination_currency", value: amt },
          recipient: { bank: { account_number: bank.account_number, code: bank.bank_code } },
        },
      },
      ref
    );

    const tData = transfer.data?.data ?? transfer.data;
    if (!transfer.ok) {
      // Transfer never left Flutterwave — reverse the hold so the money is
      // available again, and free the withdrawal ledger row from the cap.
      console.error(`Flutterwave transfer error: status=${transfer.status} body=${JSON.stringify(transfer.data)}`);
      await supabase.rpc("wallet_credit", {
        p_user_id: callerId,
        p_amount: amt,
        p_type: "reversal",
        p_reference: `rev_${ref}`,
        p_description: "Withdrawal reversal (transfer not accepted)",
      });
      await supabase.from("wallet_transactions").update({ status: "failed" }).eq("reference", ref);
      await supabase.from("withdrawals").update({ status: "failed", failure_reason: tData?.message || "transfer_rejected" }).eq("id", withdrawalId);
      return json({ error: tData?.message || "Transfer could not be initiated" }, 400);
    }

    // 4) Processing — the transfer.disburse webhook confirms/reverses.
    await supabase
      .from("withdrawals")
      .update({ status: "processing", flw_transfer_id: String(tData?.id ?? ""), flw_reference: ref })
      .eq("id", withdrawalId);

    return json({ success: true, status: "processing", withdrawal_id: withdrawalId, amount: amt, balance: newBalance });
  } catch (error: any) {
    console.error("wallet-withdraw error:", error);
    return json({ error: error.message }, 500);
  }
});
