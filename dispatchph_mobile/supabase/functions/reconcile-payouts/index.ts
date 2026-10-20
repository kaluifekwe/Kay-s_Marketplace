import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { flwGet } from "../_shared/flutterwave.ts";
import { isScheduledCaller, refusalReason } from "../_shared/cron-auth.ts";

// Scheduled reconciliation of payouts (see reconciliation.sql + recon_cron.sql).
//
// A payout is debited from the wallet, sent to Flutterwave, and finalised by the
// transfer.disburse webhook. When that webhook is missed the row sits in
// `processing` for ever: the vendor is debited, the money may or may not have
// left, and nobody finds out until someone complains. This job sweeps those
// rows and asks Flutterwave what actually happened.
//
//   SUCCESSFUL → mark success (money left; the up-front debit stands)
//   FAILED     → reverse the hold back into the wallet + mark failed
//   still in flight → leave alone; raise an exception once it is clearly overdue
//
// It deliberately never RE-SENDS a transfer: re-initiating one that had actually
// succeeded would pay the vendor twice. Reconciling means recording the truth,
// not retrying.
//
// Callable by the cron job (service role) or an administrator running it by hand.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

// Give the webhook a fair chance before treating a row as stuck.
const SETTLE_GRACE_MINUTES = 15;
// After this, a payout still in flight at the provider is an exception.
const OVERDUE_HOURS = 12;
// Cap the work per run so a backlog can't time the function out.
const BATCH = 40;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

// Scheduler or operator. Kept as a named wrapper so the call site below reads
// the same as it did before the shared helper existed.
function isServiceRoleCall(request: Request): boolean {
  return isScheduledCaller(request);
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

async function raiseException(
  supabase: ReturnType<typeof createClient>,
  e: {
    kind: string; reference?: string | null; targetId: string; amount: number;
    ourState: string; providerState?: string | null; details: string;
  },
) {
  // Refresh the existing open row rather than stacking duplicates every run —
  // the unique index makes the insert a no-op after the first sighting.
  const { data: existing } = await supabase
    .from("reconciliation_exceptions")
    .select("id")
    .eq("kind", e.kind)
    .eq("target_id", e.targetId)
    .eq("status", "open")
    .maybeSingle();

  if (existing) {
    await supabase
      .from("reconciliation_exceptions")
      .update({ last_seen_at: new Date().toISOString(), provider_state: e.providerState ?? null, details: e.details })
      .eq("id", (existing as any).id);
    return;
  }
  await supabase.from("reconciliation_exceptions").insert({
    kind: e.kind,
    reference: e.reference ?? null,
    target_type: "withdrawal",
    target_id: e.targetId,
    amount: e.amount,
    our_state: e.ourState,
    provider_state: e.providerState ?? null,
    details: e.details,
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Cron calls with the service key; an admin may also run it manually.
    if (!isServiceRoleCall(req)) {
      const callerId = getUserIdFromToken(req.headers.get("Authorization"));
      if (!callerId) {
        // A service-role token has no `sub`, so a scheduler whose credential
        // was not recognised lands here rather than in the branch above. Say so
        // in the log, otherwise it looks like an ordinary unauthenticated call.
        console.error(`reconcile-payouts: refused caller — ${refusalReason(req)}`);
        return json({ error: "Unauthorized" }, 401);
      }
      const { data: caller } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
      if (caller?.role !== "admin") return json({ error: "Admin only" }, 403);
    }

    const cutoff = new Date(Date.now() - SETTLE_GRACE_MINUTES * 60_000).toISOString();
    const { data: rows } = await supabase
      .from("withdrawals")
      .select("id, user_id, amount, status, flw_transfer_id, flw_reference, created_at")
      .eq("status", "processing")
      .lt("created_at", cutoff)
      .order("created_at", { ascending: true })
      .limit(BATCH);

    const summary = { checked: 0, settled: 0, reversed: 0, still_pending: 0, exceptions: 0, unreachable: 0 };

    for (const wd of rows ?? []) {
      summary.checked++;
      const amount = Number((wd as any).amount) || 0;
      const reference = (wd as any).flw_reference as string | null;
      const id = String((wd as any).id);

      if (!(wd as any).flw_transfer_id && !reference) {
        summary.exceptions++;
        await raiseException(supabase, {
          kind: "payout_no_reference", targetId: id, amount, ourState: "processing",
          details: "Payout is in processing but carries no provider reference, so its status cannot be checked.",
        });
        continue;
      }

      const lookup = (wd as any).flw_transfer_id
        ? `/direct-transfers/${(wd as any).flw_transfer_id}`
        : `/direct-transfers?reference=${encodeURIComponent(reference!)}`;

      let res;
      try {
        res = await flwGet(lookup);
      } catch (e) {
        summary.unreachable++;
        console.error(`reconcile-payouts: lookup threw for ${reference}:`, e);
        continue; // transient — try again next run rather than raising noise
      }
      if (!res.ok) {
        summary.unreachable++;
        console.error(`reconcile-payouts: lookup failed ${res.status} for ${reference}`);
        continue;
      }

      const obj = Array.isArray(res.data?.data) ? res.data.data[0] : (res.data?.data ?? res.data);
      const state = String(obj?.status ?? "").toLowerCase();

      if (SUCCESS.includes(state)) {
        await supabase.from("withdrawals").update({ status: "success" }).eq("id", id);
        summary.settled++;
        try {
          await supabase.from("notifications").insert({
            user_id: (wd as any).user_id,
            title: "Withdrawal sent",
            body: `₦${amount.toLocaleString()} was sent to your bank.`,
            type: "general",
          });
        } catch (_) { /* best-effort */ }
        continue;
      }

      if (FAILED.includes(state)) {
        const { error: revErr } = await supabase.rpc("wallet_credit", {
          p_user_id: (wd as any).user_id,
          p_amount: amount,
          p_type: "reversal",
          p_reference: `rev_${reference}`,
          p_description: "Withdrawal reversal (transfer failed)",
        });
        if (revErr) {
          // Money is owed back and we could not return it — this must be seen.
          summary.exceptions++;
          console.error(`reconcile-payouts: CRITICAL reversal failed for ${reference}:`, revErr);
          await raiseException(supabase, {
            kind: "payout_reversal_failed", reference, targetId: id, amount,
            ourState: "processing", providerState: state,
            details: `Provider reports the transfer failed, but returning ₦${amount.toLocaleString()} to the wallet did not succeed: ${revErr.message}`,
          });
          continue;
        }
        await supabase.from("wallet_transactions").update({ status: "failed" }).eq("reference", reference!);
        await supabase
          .from("withdrawals")
          .update({ status: "failed", failure_reason: "transfer_failed_reconciled" })
          .eq("id", id);
        summary.reversed++;
        try {
          await supabase.from("notifications").insert({
            user_id: (wd as any).user_id,
            title: "Withdrawal failed",
            body: `Your ₦${amount.toLocaleString()} withdrawal failed and was returned to your wallet.`,
            type: "general",
          });
        } catch (_) { /* best-effort */ }
        continue;
      }

      // Still in flight at the provider. Normal for a while; overdue past that.
      summary.still_pending++;
      const ageHours = (Date.now() - new Date((wd as any).created_at).getTime()) / 3_600_000;
      if (ageHours >= OVERDUE_HOURS) {
        summary.exceptions++;
        await raiseException(supabase, {
          kind: "payout_stuck", reference, targetId: id, amount,
          ourState: "processing", providerState: state || "unknown",
          details: `Payout has been in flight for ${Math.floor(ageHours)}h. Provider still reports "${state || "unknown"}".`,
        });
      }
    }

    console.log("reconcile-payouts:", JSON.stringify(summary));
    return json({ success: true, ...summary });
  } catch (error: any) {
    console.error("reconcile-payouts error:", error);
    return json({ error: error.message }, 500);
  }
});
