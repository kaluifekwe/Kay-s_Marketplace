import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logAdminAction } from "../_shared/audit.ts";

// Administrator decides a payout that auto-release deliberately would not make.
//
// Vendor-arranged deliveries where the buyer never confirmed are parked by
// auto-release-escrow (payout_held = true) rather than paid on a timer, because
// nobody independent ever attested that the parcel arrived. This is the only
// route out of that state, and it exists so held money cannot strand.
//
//   release → pay the vendor, exactly as a normal completion would
//   hold    → leave it held, recording why (e.g. still investigating)
//
// The order is claimed atomically out of payout_held, so two administrators
// cannot both release the same order and pay twice. Every decision is written
// to admin_audit_log with the actor and the stated reason: this is a judgement
// call made on incomplete evidence, so who made it and on what basis matters
// more here than almost anywhere else in the system.

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

    const { order_id, decision, reason } = await req.json();
    if (!order_id || !["release", "hold"].includes(decision)) {
      return json({ error: "order_id and decision ('release' | 'hold') are required" }, 400);
    }
    if (!reason || String(reason).trim().length < 5) {
      // The reason is the audit trail's substance. An unexplained payout on an
      // unconfirmed delivery is exactly what this control exists to prevent.
      return json({ error: "A reason is required — it is recorded against your name." }, 400);
    }

    const { data: order } = await supabase
      .from("orders")
      .select("id, vendor_id, buyer_id, total, status, payout_held, payment_released, has_dispute, delivery_type")
      .eq("id", order_id)
      .maybeSingle();

    if (!order) return json({ error: "Order not found" }, 404);
    if (!order.payout_held) return json({ error: "This order is not held.", code: "not_held" }, 409);
    if (order.payment_released) return json({ error: "Already paid.", code: "already_released" }, 409);
    if (order.has_dispute) {
      return json({
        error: "A dispute is open on this order — resolve it through the Disputes page instead.",
        code: "disputed",
      }, 409);
    }

    // ---- hold: record the decision, change nothing else.
    if (decision === "hold") {
      await supabase
        .from("orders")
        .update({ payout_hold_reason: String(reason).slice(0, 500) })
        .eq("id", order_id);
      await logAdminAction({
        adminId: callerId,
        action: "payout_hold_kept",
        targetType: "order",
        targetId: order_id,
        summary: `Kept payout held on order ${String(order_id).slice(0, 8)}`,
        metadata: { reason, amount: order.total, delivery_type: order.delivery_type },
      });
      return json({ success: true, message: "Payout remains held." });
    }

    // ---- release: claim it first so a second administrator cannot double-pay.
    const { data: claimed, error: claimErr } = await supabase
      .from("orders")
      .update({ payout_held: false, status: "auto_released" })
      .eq("id", order_id)
      .eq("payout_held", true)
      .eq("status", "shipped")
      .select("id")
      .maybeSingle();

    if (claimErr) return json({ error: claimErr.message }, 500);
    if (!claimed) {
      return json({ error: "Someone else has already actioned this order.", code: "claim_lost" }, 409);
    }

    const res = await fetch(`${supabaseUrl}/functions/v1/release-escrow`, {
      method: "POST",
      headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ order_id }),
    });
    const data = await res.json().catch(() => ({}));

    if (!res.ok || (data as any)?.error) {
      // Put it back exactly as it was. Leaving it claimed-but-unpaid would hide
      // the order from the queue with the vendor still owed.
      await supabase
        .from("orders")
        .update({ payout_held: true, status: "shipped" })
        .eq("id", order_id);
      return json({ error: (data as any)?.error || "Release failed — the order is still held." }, 502);
    }

    await logAdminAction({
      adminId: callerId,
      action: "payout_held_released",
      targetType: "order",
      targetId: order_id,
      summary: `Released ₦${Number(order.total).toLocaleString()} to the vendor on unconfirmed order ${String(order_id).slice(0, 8)}`,
      metadata: {
        reason,
        amount: order.total,
        vendor_id: order.vendor_id,
        buyer_id: order.buyer_id,
        delivery_type: order.delivery_type,
        note: "Buyer never confirmed receipt; no independent courier confirmation existed.",
      },
    });

    return json({ success: true, message: "Payout released to the vendor." });
  } catch (error: any) {
    console.error("admin-release-held-payout error:", error);
    return json({ error: error.message }, 500);
  }
});
