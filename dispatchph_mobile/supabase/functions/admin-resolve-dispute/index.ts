import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Admin fallback resolution for a dispute that the buyer and vendor could not
// settle between themselves (status awaiting_admin_decision / escalated /
// return_submitted). Two terminal decisions:
//
//   approve_refund → buyer is refunded (to wallet by default; process-refund
//                    force-routes credit-funded orders to credit). Runs the
//                    refund under the SERVICE role via process-refund, which
//                    also claws back an already-paid vendor and releases the
//                    payout hold — atomic + idempotent.
//   deny_refund    → no money moves; the buyer gets a strike (auto-flag at 3),
//                    the held vendor payout is released back to the vendor, and
//                    the order/buyer dispute locks are cleared.
//
// All logic runs server-side under the service role after an admin-role check —
// the web admin never gets write access to disputes/users/orders. Mirrors the
// proven vendor-accept-refund pattern (atomic claim + rollback on refund
// failure). verify_jwt stays ON: the caller must be an authenticated admin.

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

// Admin acts only when the parties have exhausted the negotiation-first flow and
// the dispute has reached a state that awaits an admin decision.
const ACTIONABLE_STATUSES = ["awaiting_admin_decision", "escalated", "return_submitted"];

async function notifyBuyer(
  supabase: ReturnType<typeof createClient>,
  buyerId: string,
  orderId: string,
  title: string,
  body: string,
) {
  try {
    await supabase.from("notifications").insert({
      user_id: buyerId,
      title,
      body,
      type: "dispute",
      reference_id: orderId,
    });
    const { data: tok } = await supabase
      .from("device_tokens")
      .select("fcm_token")
      .eq("user_id", buyerId)
      .maybeSingle();
    if (tok?.fcm_token) {
      await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ user_id: buyerId, title, body, data: { type: "dispute", orderId } }),
      });
    }
  } catch (_) {
    /* notifications are best-effort — never block a resolution */
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    if (!callerId) return json({ error: "Unauthorized" }, 401);

    const { dispute_id, decision, notes } = await req.json();
    if (!dispute_id) return json({ error: "Missing dispute_id" }, 400);
    if (decision !== "approve_refund" && decision !== "deny_refund") {
      return json({ error: "decision must be 'approve_refund' or 'deny_refund'" }, 400);
    }
    // A denial must carry a reason (it strikes the buyer); an approval note is optional.
    if (decision === "deny_refund" && !(notes && String(notes).trim())) {
      return json({ error: "A reason (notes) is required to deny a refund" }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // AuthZ: caller must be an admin. Checked server-side against users.role, never
    // trusted from the client.
    const { data: caller } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
    if (caller?.role !== "admin") return json({ error: "Admin only" }, 403);

    const { data: dispute } = await supabase
      .from("disputes")
      .select("id, order_id, buyer_id, vendor_id, status")
      .eq("id", dispute_id)
      .maybeSingle();
    if (!dispute) return json({ error: "Dispute not found" }, 404);

    const nowIso = new Date().toISOString();

    // ── APPROVE REFUND ──────────────────────────────────────────────────────
    if (decision === "approve_refund") {
      // Atomically claim the resolution from an actionable state so two admins
      // can't both act. Refund runs afterwards; rolled back if it fails.
      const { data: claimed } = await supabase
        .from("disputes")
        .update({
          admin_decision: "refund_approved",
          admin_decided_by: callerId,
          admin_decided_at: nowIso,
          admin_notes: notes ?? null,
          return_required: false,
          refund_method: "wallet",
          status: "resolved",
          resolution_type: "refund",
          resolved_at: nowIso,
        })
        .eq("id", dispute_id)
        .in("status", ACTIONABLE_STATUSES)
        .select("id");

      if (!claimed || claimed.length === 0) {
        return json({ success: true, message: "This dispute has already been resolved." });
      }

      const refundRes = await fetch(`${supabaseUrl}/functions/v1/process-refund`, {
        method: "POST",
        headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          order_id: dispute.order_id,
          dispute_id,
          reason: "Dispute resolved by admin in the buyer's favour",
          refund_method: "wallet",
        }),
      });
      const refundData = await refundRes.json().catch(() => ({}));

      if (!refundRes.ok) {
        // Roll the dispute back so it stays actionable rather than showing
        // "resolved" with no refund actually paid.
        console.error("admin-resolve-dispute approve: refund failed:", JSON.stringify(refundData));
        await supabase
          .from("disputes")
          .update({
            status: dispute.status,
            resolution_type: null,
            resolved_at: null,
            admin_decision: null,
            admin_decided_at: null,
          })
          .eq("id", dispute_id);
        return json(
          { error: (refundData as any)?.error || "Refund could not be processed. Please try again." },
          502,
        );
      }

      // Clear the order + buyer dispute locks (process-refund does not).
      await supabase.from("orders").update({ has_dispute: false }).eq("id", dispute.order_id);
      try {
        await supabase.from("users").update({ active_dispute_id: null }).eq("id", dispute.buyer_id);
      } catch (_) { /* guarded column on some setups — non-fatal */ }

      await notifyBuyer(
        supabase,
        dispute.buyer_id,
        dispute.order_id,
        "Refund approved",
        "Admin reviewed your dispute and approved your refund. Your money is on the way back.",
      );

      return json({ success: true, decision, refund: refundData });
    }

    // ── DENY REFUND ─────────────────────────────────────────────────────────
    // No money moves. Atomically claim from an actionable state.
    const { data: claimed } = await supabase
      .from("disputes")
      .update({
        admin_decision: "refund_denied",
        admin_decided_by: callerId,
        admin_decided_at: nowIso,
        admin_notes: notes,
        status: "denied",
        resolution_type: "rejected",
        resolved_at: nowIso,
      })
      .eq("id", dispute_id)
      .in("status", ACTIONABLE_STATUSES)
      .select("id");

    if (!claimed || claimed.length === 0) {
      return json({ success: true, message: "This dispute has already been resolved." });
    }

    // Buyer strike; auto-flag at 3 (mirrors the mobile _addStrike). Non-fatal.
    try {
      const { data: u } = await supabase
        .from("users")
        .select("dispute_strikes_count")
        .eq("id", dispute.buyer_id)
        .maybeSingle();
      const count = ((u?.dispute_strikes_count as number | null) ?? 0) + 1;
      const flagged = count >= 3;
      await supabase
        .from("users")
        .update({
          dispute_strikes_count: count,
          ...(flagged ? { dispute_flagged: true, dispute_flagged_at: nowIso } : {}),
        })
        .eq("id", dispute.buyer_id);
    } catch (e) {
      console.error("admin-resolve-dispute deny: strike failed (non-fatal):", e);
    }

    // Clear the buyer + order dispute locks.
    try {
      await supabase.from("users").update({ active_dispute_id: null }).eq("id", dispute.buyer_id);
    } catch (_) { /* guarded column — non-fatal */ }
    await supabase.from("orders").update({ has_dispute: false }).eq("id", dispute.order_id);

    // Release the held vendor payout back to the vendor (atomic + idempotent).
    const { error: relErr } = await supabase.rpc("release_dispute_payout_hold", { p_dispute_id: dispute_id });
    if (relErr) console.error("admin-resolve-dispute deny: release_dispute_payout_hold error:", relErr);

    await notifyBuyer(
      supabase,
      dispute.buyer_id,
      dispute.order_id,
      "Dispute denied",
      `Admin reviewed your dispute and denied the refund. Reason: ${notes}`,
    );

    return json({ success: true, decision });
  } catch (error: any) {
    console.error("admin-resolve-dispute error:", error);
    return json({ error: error.message }, 500);
  }
});
