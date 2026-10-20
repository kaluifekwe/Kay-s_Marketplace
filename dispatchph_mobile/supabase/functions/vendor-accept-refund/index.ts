import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Negotiation-first dispute resolution: the vendor voluntarily ACCEPTS the
// buyer's refund, resolving the dispute directly between them (no admin needed).
// Like vendor-confirm-return, this must run server-side — process-refund rejects
// a vendor caller (403), so we authenticate the vendor here, atomically claim
// the dispute, then run the refund under the SERVICE role, which also triggers
// the clawback (if the vendor was already paid) and releases the payout hold.

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

// The vendor may accept the refund any time the dispute is still live and hasn't
// already been resolved/closed. (Terminal states are excluded by the claim.)
const ACCEPTABLE_STATUSES = [
  "awaiting_vendor_response",
  "open",
  "vendor_responded",
  "evidence_submitted",
  "replacement_offered",
  "awaiting_admin_decision",
  "escalated",
];

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    if (!callerId) return json({ error: "Unauthorized" }, 401);

    const { dispute_id } = await req.json();
    if (!dispute_id) return json({ error: "Missing dispute_id" }, 400);

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: dispute } = await supabase
      .from("disputes")
      .select("id, order_id, buyer_id, vendor_id, status, refund_method")
      .eq("id", dispute_id)
      .maybeSingle();
    if (!dispute) return json({ error: "Dispute not found" }, 404);

    // Only the dispute's own vendor may accept the refund.
    if (dispute.vendor_id !== callerId) {
      return json({ error: "Only the vendor can accept this refund" }, 403);
    }

    // Atomically claim the resolution — only from a live, non-terminal state.
    const nowIso = new Date().toISOString();
    const { data: claimed } = await supabase
      .from("disputes")
      .update({
        status: "resolved",
        resolution_type: "refund",
        resolved_at: nowIso,
        admin_notes: "Vendor accepted the refund directly.",
      })
      .eq("id", dispute_id)
      .in("status", ACCEPTABLE_STATUSES)
      .select("id");

    if (!claimed || claimed.length === 0) {
      // Already resolved/closed — nothing to do. Report success so the app
      // doesn't loop retrying.
      return json({ success: true, message: "This dispute is no longer open." });
    }

    // Run the refund under the service role: credits the buyer, claws back from
    // the vendor if already paid, and releases the payout hold — all atomic.
    const refundRes = await fetch(`${supabaseUrl}/functions/v1/process-refund`, {
      method: "POST",
      headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        order_id: dispute.order_id,
        dispute_id,
        reason: "Dispute resolved — vendor accepted the refund",
        refund_method: dispute.refund_method || "wallet",
      }),
    });
    const refundData = await refundRes.json().catch(() => ({}));

    if (!refundRes.ok) {
      // Roll the dispute back so it can be retried rather than showing "resolved"
      // with no refund actually paid.
      console.error("vendor-accept-refund refund failed:", JSON.stringify(refundData));
      await supabase.from("disputes").update({
        status: dispute.status,
        resolution_type: null,
        resolved_at: null,
      }).eq("id", dispute_id);
      return json({ error: (refundData as any)?.error || "Refund could not be processed. Please try again." }, 502);
    }

    await supabase.from("orders").update({ has_dispute: false }).eq("id", dispute.order_id);

    // Clear the buyer's active-dispute lock so they aren't stuck unable to open
    // another one, and let them know.
    try {
      await supabase.from("users").update({ active_dispute_id: null }).eq("id", dispute.buyer_id);
    } catch (_) { /* guarded column on some setups — non-fatal */ }
    try {
      await supabase.from("notifications").insert({
        user_id: dispute.buyer_id,
        title: "Refund approved",
        body: "The vendor accepted your refund. Your money is on the way back.",
        type: "dispute",
        reference_id: dispute.order_id,
      });
      const { data: tok } = await supabase.from("device_tokens").select("fcm_token").eq("user_id", dispute.buyer_id).maybeSingle();
      if (tok?.fcm_token) {
        await fetch(`${supabaseUrl}/functions/v1/send-push`, {
          method: "POST",
          headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            user_id: dispute.buyer_id,
            title: "Refund approved",
            body: "The vendor accepted your refund. Your money is on the way back.",
            data: { type: "dispute", orderId: dispute.order_id },
          }),
        });
      }
    } catch (_) { /* non-fatal */ }

    return json({ success: true, refund: refundData });
  } catch (error: any) {
    console.error("vendor-accept-refund error:", error);
    return json({ error: error.message }, 500);
  }
});
