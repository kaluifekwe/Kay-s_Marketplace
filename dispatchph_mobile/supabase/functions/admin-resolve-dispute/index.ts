import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logAdminAction } from "../_shared/audit.ts";
import { getNumber } from "../_shared/settings.ts";

// Admin fallback resolution for a dispute the buyer and vendor could not settle.
// Four decisions, each gated to the states where it makes sense:
//
//   approve_refund        (awaiting_admin_decision | escalated | return_submitted)
//        → refund the buyer NOW (wallet default; process-refund force-routes
//          credit-funded orders to credit), claw back an already-paid vendor,
//          release the payout hold. Terminal.
//   approve_refund_return (awaiting_admin_decision | escalated)
//        → approve BUT require the item back first: dispute → awaiting_return
//          with a 24h return deadline. NO money moves yet; the refund fires
//          later when the vendor confirms receipt (vendor-confirm-return).
//   verify_return         (return_submitted)
//        → buyer's return photos look legit: hand off to the vendor to confirm
//          receipt within 24h (dispute → vendor_confirming). NO money moves.
//   deny_refund           (awaiting_admin_decision | escalated | return_submitted)
//        → no money moves; buyer strike (auto-flag at 3), release the held
//          vendor payout, clear locks. Terminal.
//
// All logic runs server-side under the service role after an admin-role check —
// the web admin never gets write access. Atomic claim (status guard on UPDATE)
// prevents double-resolve; the immediate refund rolls back on failure.

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

const HOUR_MS = 60 * 60 * 1000;
// Tunable in the admin console (app_settings); literals stay as fallbacks.
const RETURN_HOURS_DEFAULT = 24;
const VENDOR_CONFIRM_HOURS_DEFAULT = 24;
const DECISIONS = ["approve_refund", "approve_refund_return", "verify_return", "deny_refund"];

async function notify(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  orderId: string,
  title: string,
  body: string,
) {
  try {
    await supabase.from("notifications").insert({
      user_id: userId,
      title,
      body,
      type: "dispute",
      reference_id: orderId,
    });
    const { data: tok } = await supabase
      .from("device_tokens")
      .select("fcm_token")
      .eq("user_id", userId)
      .maybeSingle();
    if (tok?.fcm_token) {
      await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ user_id: userId, title, body, data: { type: "dispute", orderId } }),
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
    if (!DECISIONS.includes(decision)) {
      return json({ error: `decision must be one of: ${DECISIONS.join(", ")}` }, 400);
    }
    if (decision === "deny_refund" && !(notes && String(notes).trim())) {
      return json({ error: "A reason (notes) is required to deny a refund" }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: caller } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
    if (caller?.role !== "admin") return json({ error: "Admin only" }, 403);

    const { data: dispute } = await supabase
      .from("disputes")
      .select("id, order_id, buyer_id, vendor_id, status")
      .eq("id", dispute_id)
      .maybeSingle();
    if (!dispute) return json({ error: "Dispute not found" }, 404);

    const nowIso = new Date().toISOString();

    // ── APPROVE REFUND (immediate) ──────────────────────────────────────────
    if (decision === "approve_refund") {
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
        .in("status", ["awaiting_admin_decision", "escalated", "return_submitted"])
        .select("id");

      if (!claimed || claimed.length === 0) {
        return json({ success: true, message: "This dispute is not awaiting an admin decision." });
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

      await supabase.from("orders").update({ has_dispute: false }).eq("id", dispute.order_id);
      try {
        await supabase.from("users").update({ active_dispute_id: null }).eq("id", dispute.buyer_id);
      } catch (_) { /* guarded column — non-fatal */ }

      await notify(
        supabase,
        dispute.buyer_id,
        dispute.order_id,
        "Refund approved",
        "Admin reviewed your dispute and approved your refund. Your money is on the way back.",
      );
      await logAdminAction({
        adminId: callerId, action: "dispute.approve_refund", targetType: "dispute", targetId: dispute_id,
        summary: "Approved a refund and paid the buyer immediately",
        metadata: { order_id: dispute.order_id, buyer_id: dispute.buyer_id, vendor_id: dispute.vendor_id, notes: notes ?? null, refund: refundData },
      });
      return json({ success: true, decision, refund: refundData });
    }

    // ── APPROVE WITH RETURN ─────────────────────────────────────────────────
    // No money now: the buyer must ship the item back within 24h; the refund
    // fires later when the vendor confirms receipt (vendor-confirm-return).
    if (decision === "approve_refund_return") {
      const { data: claimed } = await supabase
        .from("disputes")
        .update({
          admin_decision: "refund_approved",
          admin_decided_by: callerId,
          admin_decided_at: nowIso,
          admin_notes: notes ?? null,
          return_required: true,
          return_deadline: new Date(Date.now() + (await getNumber("dispute_return_hours", "DISPUTE_RETURN_HOURS", RETURN_HOURS_DEFAULT)) * HOUR_MS).toISOString(),
          refund_method: "wallet",
          status: "awaiting_return",
        })
        .eq("id", dispute_id)
        .in("status", ["awaiting_admin_decision", "escalated"])
        .select("id");

      if (!claimed || claimed.length === 0) {
        return json({ success: true, message: "This dispute is not awaiting an admin decision." });
      }

      // Mirror the mobile flow: clear the buyer's active-dispute lock at approval
      // (vendor-confirm-return, which finalises later, does not clear it).
      try {
        await supabase.from("users").update({ active_dispute_id: null }).eq("id", dispute.buyer_id);
      } catch (_) { /* guarded column — non-fatal */ }

      await notify(
        supabase,
        dispute.buyer_id,
        dispute.order_id,
        "Refund approved — return required",
        "Admin approved your refund. Return the item within 24 hours to receive payment.",
      );
      await logAdminAction({
        adminId: callerId, action: "dispute.approve_refund_return", targetType: "dispute", targetId: dispute_id,
        summary: "Approved a refund requiring the item to be returned first",
        metadata: { order_id: dispute.order_id, buyer_id: dispute.buyer_id, vendor_id: dispute.vendor_id, notes: notes ?? null },
      });
      return json({ success: true, decision, status: "awaiting_return" });
    }

    // ── VERIFY RETURN ───────────────────────────────────────────────────────
    // Buyer's return photos look legitimate → hand off to the vendor to confirm
    // receipt within 24h. Still no money; vendor-confirm-return does the refund.
    if (decision === "verify_return") {
      const { data: claimed } = await supabase
        .from("disputes")
        .update({
          return_verified: true,
          return_verified_at: nowIso,
          status: "vendor_confirming",
          vendor_confirm_deadline: new Date(Date.now() + (await getNumber("dispute_vendor_confirm_hours", "DISPUTE_VENDOR_CONFIRM_HOURS", VENDOR_CONFIRM_HOURS_DEFAULT)) * HOUR_MS).toISOString(),
          ...(notes ? { admin_notes: notes } : {}),
        })
        .eq("id", dispute_id)
        .eq("status", "return_submitted")
        .select("id");

      if (!claimed || claimed.length === 0) {
        return json({ success: true, message: "This dispute has no submitted return to verify." });
      }

      await notify(
        supabase,
        dispute.vendor_id,
        dispute.order_id,
        "Confirm return receipt",
        "The buyer has returned the item. Confirm receipt within 24 hours, or the refund is processed automatically.",
      );
      await logAdminAction({
        adminId: callerId, action: "dispute.verify_return", targetType: "dispute", targetId: dispute_id,
        summary: "Verified the buyer return; vendor asked to confirm receipt",
        metadata: { order_id: dispute.order_id, buyer_id: dispute.buyer_id, vendor_id: dispute.vendor_id, notes: notes ?? null },
      });
      return json({ success: true, decision, status: "vendor_confirming" });
    }

    // ── DENY REFUND ─────────────────────────────────────────────────────────
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
      .in("status", ["awaiting_admin_decision", "escalated", "return_submitted"])
      .select("id");

    if (!claimed || claimed.length === 0) {
      return json({ success: true, message: "This dispute is not awaiting an admin decision." });
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

    try {
      await supabase.from("users").update({ active_dispute_id: null }).eq("id", dispute.buyer_id);
    } catch (_) { /* guarded column — non-fatal */ }
    await supabase.from("orders").update({ has_dispute: false }).eq("id", dispute.order_id);

    const { error: relErr } = await supabase.rpc("release_dispute_payout_hold", { p_dispute_id: dispute_id });
    if (relErr) console.error("admin-resolve-dispute deny: release_dispute_payout_hold error:", relErr);

    await notify(
      supabase,
      dispute.buyer_id,
      dispute.order_id,
      "Dispute denied",
      `Admin reviewed your dispute and denied the refund. Reason: ${notes}`,
    );
    await logAdminAction({
      adminId: callerId, action: "dispute.deny_refund", targetType: "dispute", targetId: dispute_id,
      summary: `Denied the refund — ${notes}`,
      metadata: { order_id: dispute.order_id, buyer_id: dispute.buyer_id, vendor_id: dispute.vendor_id, notes: notes ?? null },
    });
    return json({ success: true, decision });
  } catch (error: any) {
    console.error("admin-resolve-dispute error:", error);
    return json({ error: error.message }, 500);
  }
});
