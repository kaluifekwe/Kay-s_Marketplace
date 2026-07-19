import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Runs on a schedule (pg_cron, see auto_release_cron.sql) instead of relying
// on a Dart Timer inside the app — escrow release and dispute escalation
// must happen even if no one has the app open near the deadline.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Only the service role (pg_cron / internal calls) may trigger this.
  const authHeader = req.headers.get("Authorization") || "";
  if (authHeader.replace("Bearer ", "") !== supabaseServiceKey) {
    return new Response(JSON.stringify({ error: "Forbidden" }), {
      status: 403,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(supabaseUrl, supabaseServiceKey);
  const now = new Date().toISOString();
  const released: string[] = [];
  const releaseErrors: Record<string, string> = {};

  const flaggedForReview: string[] = [];
  // Vendor-arranged orders parked for an administrator instead of auto-released.
  const heldForDecision: string[] = [];

  try {
    // ---- 1a. At the 24h mark, a still-silent buyer (no confirm, no dispute)
    // doesn't get an instant payout to the vendor — admin gets escalated and
    // the money sits with us for a further 12h grace period first. A buyer
    // who explicitly disputes non-delivery is excluded here (has_dispute is
    // already true) because that's handled by the normal dispute flow below,
    // which already blocks release until resolved.
    const { data: toFlag } = await supabase
      .from("orders")
      .select("id, buyer_id, vendor_id")
      .eq("status", "shipped")
      .eq("has_dispute", false)
      .eq("admin_review_flagged", false)
      .not("auto_release_at", "is", null)
      .lt("auto_release_at", now);

    for (const order of toFlag || []) {
      const extendedReleaseAt = new Date(Date.now() + 12 * 60 * 60 * 1000).toISOString();
      const { error: flagError } = await supabase
        .from("orders")
        .update({
          admin_review_flagged: true,
          admin_review_flagged_at: now,
          extended_release_at: extendedReleaseAt,
        })
        .eq("id", order.id)
        .eq("status", "shipped")
        .eq("admin_review_flagged", false); // guards against double-processing

      if (flagError) continue;
      flaggedForReview.push(order.id);

      const { data: admins } = await supabase.from("users").select("id").eq("role", "admin");
      for (const admin of admins || []) {
        await fetch(`${supabaseUrl}/functions/v1/send-push`, {
          method: "POST",
          headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            user_id: admin.id,
            title: "Order needs review",
            body: `Buyer hasn't confirmed order #${String(order.id).substring(0, 8)} 24h after shipment. Payout held for 12h.`,
            data: { type: "order_review", orderId: order.id },
          }),
        }).catch((e) => console.error("admin escalation push failed:", e));
      }
    }

    // ---- 1b. Release escrow for flagged orders whose 12h grace period has
    // also passed, as long as no dispute has since been opened.
    //
    // COURIER ORDERS ONLY. On a courier delivery the "delivered" state was
    // written by the courier company's own system through a server-to-server
    // webhook, so an independent third party has attested that the parcel
    // arrived. Releasing on a silent buyer is reasonable: we have evidence.
    //
    // On a VENDOR-ARRANGED delivery there is no such attestation. The vendor
    // marked their own order shipped and supplied the only photograph, so
    // releasing on silence would pay the vendor on their own word, with the
    // 12h admin notification serving as the sole check — and a notification
    // nobody opens is not a check. Those orders stay held, in the admin
    // queue, until a person decides. See the query below.
    const { data: dueOrders } = await supabase
      .from("orders")
      .select("id, buyer_id")
      .eq("status", "shipped")
      .eq("admin_review_flagged", true)
      .eq("has_dispute", false)
      .eq("delivery_type", "courier")
      .not("extended_release_at", "is", null)
      .lt("extended_release_at", now);

    for (const order of dueOrders || []) {
      // Mark as auto_released first so release-escrow's status check passes —
      // mirrors the previous client-side _autoRelease behavior.
      const { error: statusError } = await supabase
        .from("orders")
        .update({ status: "auto_released" })
        .eq("id", order.id)
        .eq("status", "shipped"); // guards against double-processing

      if (statusError) {
        releaseErrors[order.id] = statusError.message;
        continue;
      }

      try {
        const res = await fetch(`${supabaseUrl}/functions/v1/release-escrow`, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${supabaseServiceKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ order_id: order.id }),
        });
        const data = await res.json();
        if (res.ok) {
          released.push(order.id);

          // Award cashback the same way confirmDelivery does for manually
          // confirmed orders — auto-release is just a different way the
          // sale completed, the buyer still earned cashback on it.
          if (order.buyer_id) {
            try {
              const cashbackRes = await fetch(`${supabaseUrl}/functions/v1/cashback-credit`, {
                method: "POST",
                headers: {
                  Authorization: `Bearer ${supabaseServiceKey}`,
                  "Content-Type": "application/json",
                },
                body: JSON.stringify({ order_id: order.id, buyer_id: order.buyer_id }),
              });
              const cashbackData = await cashbackRes.json();
              if (cashbackRes.ok && cashbackData.cashback_amount) {
                await fetch(`${supabaseUrl}/functions/v1/send-push`, {
                  method: "POST",
                  headers: {
                    Authorization: `Bearer ${supabaseServiceKey}`,
                    "Content-Type": "application/json",
                  },
                  body: JSON.stringify({
                    user_id: order.buyer_id,
                    title: "🎉 Cashback Earned!",
                    body: `You earned ₦${cashbackData.cashback_amount} cashback from your purchase!`,
                    data: { type: "cashback", orderId: order.id },
                  }),
                });
              }
            } catch (cashbackErr) {
              console.error(`Cashback award failed for order ${order.id}:`, cashbackErr);
            }
          }
        } else {
          releaseErrors[order.id] = data.error || "release-escrow failed";
        }
      } catch (e: any) {
        releaseErrors[order.id] = e.message;
      }
    }

    // ---- 1b-ii. Vendor-arranged deliveries whose grace has also expired.
    // These are NOT released (see 1b). They are marked held so they surface in
    // the admin queue as an outstanding decision rather than sitting in
    // `shipped` looking like any other in-flight order — an invisible hold is
    // just a different way to lose the money. Admins are told once, when the
    // hold starts; the flag then persists until someone acts on it.
    const { data: toHold } = await supabase
      .from("orders")
      .select("id, vendor_id, total")
      .eq("status", "shipped")
      .eq("admin_review_flagged", true)
      .eq("has_dispute", false)
      .eq("payout_held", false)
      .neq("delivery_type", "courier")
      .not("extended_release_at", "is", null)
      .lt("extended_release_at", now);

    for (const order of toHold || []) {
      const { error: holdErr } = await supabase
        .from("orders")
        .update({
          payout_held: true,
          payout_held_at: now,
          payout_hold_reason:
            "Vendor-arranged delivery: buyer never confirmed receipt and no courier confirmed delivery independently.",
        })
        .eq("id", order.id)
        .eq("status", "shipped")
        .eq("payout_held", false); // claim, so two runs cannot both notify

      if (holdErr) {
        releaseErrors[order.id] = holdErr.message;
        continue;
      }
      heldForDecision.push(order.id);

      const { data: admins } = await supabase.from("users").select("id").eq("role", "admin");
      for (const admin of admins || []) {
        await fetch(`${supabaseUrl}/functions/v1/send-push`, {
          method: "POST",
          headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            user_id: admin.id,
            title: "Payout held — decision needed",
            body:
              `Order #${String(order.id).substring(0, 8)} was delivered by the vendor, not a courier, ` +
              `and the buyer never confirmed. Nothing has been paid. Review it.`,
            data: { type: "payout_held", orderId: order.id },
          }),
        }).catch((e) => console.error("payout-hold push failed:", e));
      }
    }

    // ---- 1c. Buyer confirmation reminders ----
    // While the delivery-confirmation window is still open (shipped, not yet due,
    // no dispute), nudge the buyer roughly every 6h to confirm receipt. This
    // makes auto-release fair — the buyer is repeatedly warned, not surprised —
    // and undercuts a later "I was never told to confirm" / "not received" claim.
    // The first nudge lands ~6h after the window opened (shipped_at), so it never
    // doubles up with the "Order Shipped/Arrived" push.
    const { data: toRemind } = await supabase
      .from("orders")
      .select("id, buyer_id, auto_release_at, shipped_at, confirm_last_reminder_at")
      .eq("status", "shipped")
      .eq("has_dispute", false)
      .not("auto_release_at", "is", null)
      .gt("auto_release_at", now);

    const buyerReminders: string[] = [];
    for (const order of toRemind || []) {
      if (!order.buyer_id) continue;
      // Baseline for the 6h cadence: the last reminder, or (first time) when the
      // window opened. Fall back to auto_release_at - 24h if shipped_at is unset.
      const windowOpenedAt = order.shipped_at
        ? new Date(order.shipped_at)
        : new Date(new Date(order.auto_release_at).getTime() - 24 * 60 * 60 * 1000);
      const baseline = order.confirm_last_reminder_at ? new Date(order.confirm_last_reminder_at) : windowOpenedAt;
      if (Date.now() - baseline.getTime() < 6 * 60 * 60 * 1000) continue;

      const remainingMs = new Date(order.auto_release_at).getTime() - Date.now();
      const remHours = Math.max(0, Math.floor(remainingMs / (60 * 60 * 1000)));
      const remMins = Math.max(0, Math.floor((remainingMs % (60 * 60 * 1000)) / (60 * 1000)));

      await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          user_id: order.buyer_id,
          title: "Confirm you received your order",
          body: `Confirm order #${String(order.id).substring(0, 8)} if you've received it — or report a problem if you haven't. It completes automatically in ${remHours}h ${remMins}m.`,
          data: { type: "order", orderId: order.id, screen: "buyer_orders" },
        }),
      }).catch((e) => console.error("buyer confirm reminder push failed:", e));

      await supabase.from("orders").update({ confirm_last_reminder_at: now }).eq("id", order.id);
      buyerReminders.push(order.id);
    }

    // ---- 2. Auto-escalate disputes whose vendor missed the 24h response window ----
    const { data: escalated, error: escalateError } = await supabase
      .from("disputes")
      .update({ escalated_to_admin: true, status: "escalated" })
      .eq("status", "awaiting_vendor_response")
      .lt("vendor_response_deadline", now)
      .select("id");

    // Legacy disputes still on the old 48h single-deadline flow
    const { data: legacyEscalated } = await supabase
      .from("disputes")
      .update({ escalated_to_admin: true, status: "escalated" })
      .lt("resolution_deadline", now)
      .in("status", ["open", "vendor_responded", "evidence_submitted", "replacement_offered"])
      .select("id");

    // ---- 3. Auto-close disputes where the buyer missed the return deadline ----
    // Buyer never shipped the item back in time after admin approved a
    // return-required refund — close the dispute, give the buyer a strike,
    // and re-open the order for normal escrow handling.
    const { data: missedReturns } = await supabase
      .from("disputes")
      .select("id, buyer_id, order_id")
      .eq("status", "awaiting_return")
      .lt("return_deadline", now);

    const autoClosed: string[] = [];
    for (const d of missedReturns || []) {
      const { error: closeError } = await supabase
        .from("disputes")
        .update({ status: "auto_closed", auto_closed: true, resolved_at: now })
        .eq("id", d.id)
        .eq("status", "awaiting_return"); // guards against double-processing
      if (closeError) continue;
      autoClosed.push(d.id);

      await supabase.from("orders").update({ has_dispute: false }).eq("id", d.order_id);

      const { data: buyer } = await supabase
        .from("users")
        .select("dispute_strikes_count")
        .eq("id", d.buyer_id)
        .maybeSingle();
      const count = ((buyer?.dispute_strikes_count as number | undefined) || 0) + 1;
      const flagged = count >= 3;
      await supabase
        .from("users")
        .update({
          dispute_strikes_count: count,
          active_dispute_id: null,
          ...(flagged ? { dispute_flagged: true, dispute_flagged_at: now } : {}),
        })
        .eq("id", d.buyer_id);
    }

    // ---- 4. Vendor return-confirmation: 6h reminders + 24h auto-resolve ----
    // If the vendor ignores the confirm window entirely, the return is
    // auto-verified, the refund is processed anyway, and the vendor gets a
    // warning strike (3 warnings flags their store) — they don't get to
    // block a buyer's refund by silence.
    const { data: pendingConfirm } = await supabase
      .from("disputes")
      .select("id, order_id, buyer_id, vendor_id, refund_method, vendor_confirm_deadline, vendor_confirm_last_reminder_at, is_post_payment, vendor_owes_refund")
      .eq("status", "vendor_confirming");

    const autoVerified: string[] = [];
    for (const d of pendingConfirm || []) {
      const deadline = d.vendor_confirm_deadline ? new Date(d.vendor_confirm_deadline) : null;
      if (!deadline) continue;

      if (deadline.getTime() <= Date.now()) {
        const { error: resolveError } = await supabase
          .from("disputes")
          .update({
            status: "resolved",
            resolution_type: "refund",
            resolved_at: now,
            admin_notes: "Auto-verified: vendor did not confirm or deny within 24 hours.",
          })
          .eq("id", d.id)
          .eq("status", "vendor_confirming"); // guards against double-processing
        if (resolveError) continue;
        autoVerified.push(d.id);

        try {
          const refundRes = await fetch(`${supabaseUrl}/functions/v1/process-refund`, {
            method: "POST",
            headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
            body: JSON.stringify({
              order_id: d.order_id,
              dispute_id: d.id,
              reason: "Dispute resolved — vendor missed return-confirmation window",
              refund_method: d.refund_method || "credit",
            }),
          });
          if (!refundRes.ok) {
            const errBody = await refundRes.json();
            console.error(`Auto-refund failed for dispute ${d.id}:`, errBody);
          }
        } catch (e) {
          console.error(`Auto-refund request failed for dispute ${d.id}:`, e);
        }

        await supabase.from("orders").update({ has_dispute: false }).eq("id", d.order_id);

        // Release any payout hold tied to this dispute now that it's settled.
        // process-refund (called just above) already releases it; this is an
        // idempotent belt-and-braces call (the claim on payout_hold_released
        // makes the second call a no-op) in case that request failed.
        await supabase.rpc("release_dispute_payout_hold", { p_dispute_id: d.id });

        // Vendor warning for missing the confirmation window.
        const { data: vendorRow } = await supabase
          .from("users")
          .select("vendor_warnings_count")
          .eq("id", d.vendor_id)
          .maybeSingle();
        const warningCount = ((vendorRow?.vendor_warnings_count as number | undefined) || 0) + 1;
        const vendorFlagged = warningCount >= 3;
        await supabase
          .from("users")
          .update({
            vendor_warnings_count: warningCount,
            ...(vendorFlagged ? { vendor_flagged: true, vendor_flagged_at: now } : {}),
          })
          .eq("id", d.vendor_id);

        await fetch(`${supabaseUrl}/functions/v1/send-push`, {
          method: "POST",
          headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            user_id: d.vendor_id,
            title: vendorFlagged ? "⚠️ Store Flagged for Review" : `Warning ${warningCount}/3`,
            body: vendorFlagged
              ? "Your store has been flagged for review due to repeated policy violations. Contact support."
              : `Please confirm return receipts promptly. ${3 - warningCount} more warnings will flag your store.`,
            data: { type: "dispute", orderId: d.order_id },
          }),
        }).catch((e) => console.error("vendor warning push failed:", e));

        await fetch(`${supabaseUrl}/functions/v1/send-push`, {
          method: "POST",
          headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            user_id: d.buyer_id,
            title: "✅ Return Verified Automatically",
            body: "The vendor did not respond in time, so your return was auto-verified and your refund has been processed.",
            data: { type: "dispute", orderId: d.order_id },
          }),
        }).catch((e) => console.error("buyer auto-verify push failed:", e));
      } else {
        // Send a reminder roughly every 6 hours while waiting.
        const lastReminder = d.vendor_confirm_last_reminder_at ? new Date(d.vendor_confirm_last_reminder_at) : null;
        const dueForReminder = !lastReminder || Date.now() - lastReminder.getTime() >= 6 * 60 * 60 * 1000;
        if (dueForReminder) {
          const remainingMs = deadline.getTime() - Date.now();
          const remHours = Math.floor(remainingMs / (60 * 60 * 1000));
          const remMins = Math.floor((remainingMs % (60 * 60 * 1000)) / (60 * 1000));
          await fetch(`${supabaseUrl}/functions/v1/send-push`, {
            method: "POST",
            headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
            body: JSON.stringify({
              user_id: d.vendor_id,
              title: "⚠️ Confirm Return Receipt",
              body: `Please confirm return receipt for order #${String(d.order_id).substring(0, 8)}. ${remHours}h ${remMins}m remaining before automatic refund.`,
              data: { type: "dispute", orderId: d.order_id },
            }),
          }).catch((e) => console.error("vendor reminder push failed:", e));
          await supabase.from("disputes").update({ vendor_confirm_last_reminder_at: now }).eq("id", d.id);
        }
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        orders_released: released,
        orders_flagged_for_review: flaggedForReview,
        payouts_held_for_decision: heldForDecision,
        buyer_confirm_reminders: buyerReminders,
        order_errors: releaseErrors,
        disputes_escalated: (escalated?.length || 0) + (legacyEscalated?.length || 0),
        disputes_auto_closed: autoClosed,
        disputes_auto_verified: autoVerified,
        escalate_error: escalateError?.message,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: any) {
    console.error("auto-release-escrow error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
