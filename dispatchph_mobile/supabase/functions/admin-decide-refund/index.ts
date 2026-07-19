import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logAdminAction } from "../_shared/audit.ts";

// Administrator approves or rejects a buyer's refund request.
//
// Approval is the ONLY path that moves money here: it delegates to
// process-refund under the service role, which pays the buyer's verified bank
// account via Flutterwave, claws back an already-paid vendor and is idempotent
// on the order reference.
//
// Rejection moves nothing and restores the order to 'paid' so the buyer is not
// left in limbo with an order stuck in refund_requested.
//
// The request is claimed atomically out of 'pending', so two administrators
// cannot both approve the same refund and pay twice. If the refund itself then
// fails, the claim is rolled back so it returns to the queue rather than
// showing as approved with no money sent.

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

async function notifyBuyer(
  supabase: ReturnType<typeof createClient>,
  buyerId: string,
  orderId: string,
  title: string,
  body: string,
) {
  try {
    await supabase.from("notifications").insert({
      user_id: buyerId, title, body, type: "general", reference_id: orderId,
    });
    const { data: tok } = await supabase
      .from("device_tokens").select("fcm_token").eq("user_id", buyerId).maybeSingle();
    if (tok?.fcm_token) {
      await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ user_id: buyerId, title, body, data: { type: "refund", orderId } }),
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

    const { request_id, decision, notes } = await req.json();
    if (!request_id) return json({ error: "Missing request_id" }, 400);
    if (decision !== "approve" && decision !== "reject") {
      return json({ error: "decision must be 'approve' or 'reject'" }, 400);
    }
    if (decision === "reject" && !(notes && String(notes).trim())) {
      return json({ error: "A reason is required to reject a refund" }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: caller } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
    if (caller?.role !== "admin") return json({ error: "Admin only" }, 403);

    const { data: rr } = await supabase
      .from("refund_requests")
      .select("id, order_id, buyer_id, amount, status, reason")
      .eq("id", request_id)
      .maybeSingle();
    if (!rr) return json({ error: "Refund request not found" }, 404);

    const nowIso = new Date().toISOString();
    const amount = Number(rr.amount) || 0;

    // ── REJECT ──────────────────────────────────────────────────────────────
    if (decision === "reject") {
      const { data: claimed } = await supabase
        .from("refund_requests")
        .update({ status: "rejected", admin_id: callerId, admin_notes: notes, decided_at: nowIso })
        .eq("id", request_id)
        .eq("status", "pending")
        .select("id");
      if (!claimed || claimed.length === 0) {
        return json({ success: true, message: "This request has already been decided." });
      }

      // Put the order back so it isn't stranded in refund_requested.
      await supabase.from("orders").update({ status: "paid" }).eq("id", rr.order_id);

      await notifyBuyer(
        supabase, rr.buyer_id, rr.order_id,
        "Refund request declined",
        `Your refund request was declined. Reason: ${notes}`,
      );
      await logAdminAction({
        adminId: callerId, action: "refund.reject", targetType: "order", targetId: rr.order_id,
        summary: `Declined a ₦${amount.toLocaleString()} refund request — ${notes}`,
        metadata: { request_id, amount, buyer_id: rr.buyer_id, notes },
      });
      return json({ success: true, decision: "rejected" });
    }

    // ── APPROVE ─────────────────────────────────────────────────────────────
    // Claim first so two admins cannot both trigger a payout.
    const { data: claimed } = await supabase
      .from("refund_requests")
      .update({ status: "approved", admin_id: callerId, admin_notes: notes ?? null, decided_at: nowIso })
      .eq("id", request_id)
      .eq("status", "pending")
      .select("id");
    if (!claimed || claimed.length === 0) {
      return json({ success: true, message: "This request has already been decided." });
    }

    const refundRes = await fetch(`${supabaseUrl}/functions/v1/process-refund`, {
      method: "POST",
      headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        order_id: rr.order_id,
        reason: rr.reason || "Refund approved by admin",
      }),
    });
    const refundData = await refundRes.json().catch(() => ({}));

    if (!refundRes.ok) {
      // Return it to the queue rather than showing approved with no money sent.
      console.error("admin-decide-refund: refund failed:", JSON.stringify(refundData));
      await supabase
        .from("refund_requests")
        .update({ status: "pending", admin_id: null, decided_at: null })
        .eq("id", request_id);
      return json(
        { error: (refundData as any)?.error || "Refund could not be processed. The request stays in the queue." },
        502,
      );
    }

    await notifyBuyer(
      supabase, rr.buyer_id, rr.order_id,
      "Refund approved",
      `Your ₦${amount.toLocaleString()} refund was approved and is on its way to your bank account.`,
    );
    await logAdminAction({
      adminId: callerId, action: "refund.approve", targetType: "order", targetId: rr.order_id,
      summary: `Approved a ₦${amount.toLocaleString()} refund to the buyer's bank account`,
      metadata: { request_id, amount, buyer_id: rr.buyer_id, refund: refundData },
    });

    return json({ success: true, decision: "approved", refund: refundData });
  } catch (error: any) {
    console.error("admin-decide-refund error:", error);
    return json({ error: error.message }, 500);
  }
});
