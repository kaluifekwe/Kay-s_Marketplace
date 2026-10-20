import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// The vendor confirms they received a returned item, which should finalize the
// buyer's refund. This used to be done in the app: dispute_bloc called
// process-refund directly, but process-refund only accepts the BUYER, an admin,
// or the service role — so a vendor-initiated call was rejected with 403 and the
// refund silently never happened (only the 24h auto-timeout, which runs as the
// service role, actually refunded). This function fixes that: it authenticates
// the vendor, atomically claims the dispute out of `vendor_confirming`, then
// invokes process-refund with the SERVICE key so the refund + clawback + payout-
// hold release all run under a trusted context.

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

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    if (!callerId) return json({ error: "Unauthorized" }, 401);

    const { dispute_id, received_photo_url } = await req.json();
    if (!dispute_id) return json({ error: "Missing dispute_id" }, 400);

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: dispute } = await supabase
      .from("disputes")
      .select("id, order_id, buyer_id, vendor_id, status, refund_method")
      .eq("id", dispute_id)
      .maybeSingle();
    if (!dispute) return json({ error: "Dispute not found" }, 404);

    // Only the dispute's own vendor may confirm the return.
    if (dispute.vendor_id !== callerId) {
      return json({ error: "Only the vendor can confirm this return" }, 403);
    }

    // Atomically claim the confirmation — only valid while the dispute is
    // awaiting the vendor's receipt confirmation (admin already verified the
    // buyer's return). This guards against double-submits and out-of-order calls.
    const nowIso = new Date().toISOString();
    const { data: claimed } = await supabase
      .from("disputes")
      .update({
        vendor_return_received_photo: received_photo_url ?? null,
        vendor_return_confirmed_at: nowIso,
        status: "resolved",
        resolution_type: "refund",
        resolved_at: nowIso,
      })
      .eq("id", dispute_id)
      .eq("status", "vendor_confirming")
      .select("id");

    if (!claimed || claimed.length === 0) {
      // Not in the confirmable state (already processed, or admin hasn't verified
      // the return yet). Nothing to do — report success so the app doesn't retry.
      return json({ success: true, message: "Return is not awaiting your confirmation." });
    }

    // Finalize the refund under the service role (authorized). process-refund
    // credits the buyer, claws back from the vendor if already paid, and releases
    // the payout hold — all atomic/idempotent.
    const refundRes = await fetch(`${supabaseUrl}/functions/v1/process-refund`, {
      method: "POST",
      headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        order_id: dispute.order_id,
        dispute_id,
        reason: "Dispute resolved — vendor confirmed return received",
        refund_method: dispute.refund_method || "credit",
      }),
    });
    const refundData = await refundRes.json().catch(() => ({}));

    if (!refundRes.ok) {
      // Refund failed — roll the dispute back so it can be retried rather than
      // leaving it "resolved" with no refund actually paid.
      console.error("vendor-confirm-return refund failed:", JSON.stringify(refundData));
      await supabase.from("disputes").update({ status: "vendor_confirming" }).eq("id", dispute_id);
      return json({ error: (refundData as any)?.error || "Refund could not be processed. Please try again." }, 502);
    }

    await supabase.from("orders").update({ has_dispute: false }).eq("id", dispute.order_id);

    // Let the buyer know their refund went through.
    try {
      await supabase.from("notifications").insert({
        user_id: dispute.buyer_id,
        title: "Return Confirmed — Refund Processed",
        body: "The vendor confirmed your return. Your refund has been processed.",
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
            title: "Return Confirmed — Refund Processed",
            body: "The vendor confirmed your return. Your refund has been processed.",
            data: { type: "dispute", orderId: dispute.order_id },
          }),
        });
      }
    } catch (_) { /* non-fatal */ }

    return json({ success: true, refund: refundData });
  } catch (error: any) {
    console.error("vendor-confirm-return error:", error);
    return json({ error: error.message }, 500);
  }
});
