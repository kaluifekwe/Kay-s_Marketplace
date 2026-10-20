import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Buyer accepts the vendor's replacement offer. The original payment stays in
// escrow (no refund, no release yet) and the order is reset to "paid" so the
// vendor ships the REPLACEMENT and the buyer confirms it on arrival — the normal
// delivery/confirm/release cycle then completes the sale. Runs server-side
// because it must clear the buyer's guarded active-dispute lock and reset
// protected order fields, which a client can't touch directly.

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

    const { dispute_id } = await req.json();
    if (!dispute_id) return json({ error: "Missing dispute_id" }, 400);

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: dispute } = await supabase
      .from("disputes")
      .select("id, order_id, buyer_id, vendor_id, status")
      .eq("id", dispute_id)
      .maybeSingle();
    if (!dispute) return json({ error: "Dispute not found" }, 404);

    // Only the dispute's own buyer may accept the replacement.
    if (dispute.buyer_id !== callerId) {
      return json({ error: "Only the buyer can accept this replacement" }, 403);
    }

    // Atomically claim it — only valid while a replacement is actually on offer.
    const nowIso = new Date().toISOString();
    const { data: claimed } = await supabase
      .from("disputes")
      .update({ status: "replacement_accepted", resolution_type: "replacement", resolved_at: nowIso })
      .eq("id", dispute_id)
      .eq("status", "replacement_offered")
      .select("id");

    if (!claimed || claimed.length === 0) {
      return json({ success: true, message: "No replacement is awaiting your acceptance." });
    }

    // Reset the order so the vendor ships the replacement: back to "paid"
    // (awaiting shipment), dispute cleared, delivery timers reset. The payment
    // stays in escrow (payment_released untouched), so the buyer is still
    // protected until they confirm the replacement arrives.
    await supabase
      .from("orders")
      .update({
        status: "paid",
        has_dispute: false,
        auto_release_at: null,
        shipped_at: null,
        admin_review_flagged: false,
      })
      .eq("id", dispute.order_id);

    // Clear the buyer's active-dispute lock (guarded column — service role only).
    await supabase.from("users").update({ active_dispute_id: null }).eq("id", dispute.buyer_id);

    // Tell the vendor to ship the replacement.
    try {
      await supabase.from("notifications").insert({
        user_id: dispute.vendor_id,
        title: "Replacement accepted — please ship",
        body: "The buyer accepted your replacement. Please ship it and mark the order as shipped.",
        type: "vendor_order",
        reference_id: dispute.order_id,
      });
      const { data: tok } = await supabase.from("device_tokens").select("fcm_token").eq("user_id", dispute.vendor_id).maybeSingle();
      if (tok?.fcm_token) {
        await fetch(`${supabaseUrl}/functions/v1/send-push`, {
          method: "POST",
          headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            user_id: dispute.vendor_id,
            title: "Replacement accepted — please ship",
            body: "The buyer accepted your replacement. Ship it and mark the order shipped.",
            data: { type: "order", orderId: dispute.order_id, screen: "vendor_orders" },
          }),
        });
      }
    } catch (_) { /* non-fatal */ }

    return json({ success: true });
  } catch (error: any) {
    console.error("accept-replacement error:", error);
    return json({ error: error.message }, 500);
  }
});
