import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getNumber } from "../_shared/settings.ts";

// Completes a checkout that is fully covered by the buyer's Kay's Credit
// balance (no card charge). Mirrors paystack-webhook's order-creation logic
// (recomputes real prices server-side, one order per vendor) so a
// credit-paid order behaves identically to a card-paid one from here on —
// the vendor still gets shipped/confirmed/paid via the normal escrow flow,
// funded from the platform's own balance instead of a new card charge.
//
// Only supports credit fully covering the order. Partial credit + card
// combination is not supported yet (rejected with an error).

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

// A chat-negotiated delivery fee is valid for this long (from the vendor's offer)
// before checkout must use a freshly re-quoted fee.
// Tunable in the admin console (app_settings); literal stays as the fallback.
const DELIVERY_FEE_VALID_MINUTES_DEFAULT = 60;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({ error: "Method not allowed" }), {
        status: 405,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    const { buyer_id, vendor_orders } = await req.json();

    if (!buyer_id || !vendor_orders || !Array.isArray(vendor_orders) || vendor_orders.length === 0) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: buyer_id, vendor_orders" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!callerId || callerId !== buyer_id) {
      return new Response(
        JSON.stringify({ error: "Authenticated user does not match buyer_id" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // KYC gate: a buyer must be identity-verified (NIN) before they can buy.
    const { data: buyerKyc } = await supabase
      .from("users")
      .select("kyc_status")
      .eq("id", buyer_id)
      .maybeSingle();
    if (buyerKyc?.kyc_status !== "verified") {
      return new Response(
        JSON.stringify({ error: "kyc_required", message: "Verify your identity (NIN) before buying." }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Recompute every vendor's subtotal from real product/variant prices —
    // never trust client-supplied prices/subtotals. Delivery fee is
    // resolved the same way create-payment does it for card checkout: read
    // from the latest accepted chat message between buyer and vendor, never
    // from the client. This is the credit-checkout counterpart of the same
    // "buyer never actually pays delivery fee" bug fixed for card payments.
    const verifiedOrders: {
      vendorId: string;
      storeId: string;
      items: any[];
      subtotal: number;
      deliveryFee: number;
      deliveryType: string;
      vendorContribution: number;
      courierQuoteId: string | null;
      courierName: string | null;
      courierProvider: string | null;
    }[] = [];
    let total = 0;

    for (const vendorOrder of vendor_orders) {
      const vendorId = vendorOrder.vendor_id;
      const items = vendorOrder.items || [];
      if (!vendorId || items.length === 0) continue;

      const productIds = [...new Set(items.map((it: any) => it.product_id).filter(Boolean))];
      const { data: products } = productIds.length
        ? await supabase.from("products").select("id, price, delivery_type").in("id", productIds)
        : { data: [] };
      const priceById = new Map((products || []).map((p: any) => [p.id, Number(p.price)]));

      let subtotal = 0;
      let priceMismatch = false;
      for (const it of items) {
        const qty = Number(it.quantity) || 0;
        let unitPrice = priceById.get(it.product_id);

        if (it.variant_label) {
          const { data: variant } = await supabase
            .from("product_variants")
            .select("price")
            .eq("product_id", it.product_id)
            .eq("label", it.variant_label)
            .maybeSingle();
          if (variant) unitPrice = Number(variant.price);
        }

        if (unitPrice === undefined) {
          priceMismatch = true;
          continue;
        }
        subtotal += unitPrice * qty;
      }

      if (priceMismatch) {
        return new Response(
          JSON.stringify({ error: `Could not verify prices for vendor ${vendorId}` }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      let deliveryType = (products || []).find((p: any) => p.id === items[0]?.product_id)?.delivery_type || "negotiate";
      let deliveryFee = 0;
      let vendorContribution = 0;
      let courierQuoteId: string | null = null;
      let courierName: string | null = null;
      let courierProvider: string | null = null;
      const err = (body: any, status = 400) =>
        new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

      if (vendorOrder.delivery_quote_id && vendorOrder.selected_courier_name) {
        // A courier was selected — verify the quote and use its fee (platform
        // pays the courier, so the vendor is NOT credited the delivery fee).
        const { data: quote } = await supabase
          .from("delivery_quotes")
          .select("available_couriers, expires_at, buyer_id, vendor_id")
          .eq("id", vendorOrder.delivery_quote_id)
          .maybeSingle();
        if (!quote || quote.buyer_id !== buyer_id || quote.vendor_id !== vendorId) {
          return err({ error: "invalid_quote", message: "Delivery quote not found for this order.", vendor_id: vendorId });
        }
        if (quote.expires_at && new Date(quote.expires_at) < new Date()) {
          return err({ error: "quote_expired", message: "Your delivery quote expired. Please refresh delivery options.", vendor_id: vendorId });
        }
        const couriers = quote.available_couriers?.couriers || [];
        const selected = couriers.find((c: any) =>
          vendorOrder.selected_option_ref ? c.optionRef === vendorOrder.selected_option_ref : c.name === vendorOrder.selected_courier_name);
        if (!selected) return err({ error: "courier_unavailable", message: "Selected courier is no longer available.", vendor_id: vendorId });
        deliveryFee = Number(selected.fee) || 0;
        deliveryType = "courier";
        courierQuoteId = vendorOrder.delivery_quote_id;
        courierName = selected.name;
        courierProvider = selected.provider;
      } else if (deliveryType === "free") {
        deliveryFee = 0;
      } else {
        // No courier selected and not free → use the fee agreed with the vendor
        // in chat, regardless of the product's delivery_type (mirrors the app).
        const { data: chats } = await supabase
          .from("chats")
          .select("id")
          .eq("buyer_id", buyer_id)
          .eq("vendor_id", vendorId);
        const chatIds = (chats || []).map((c: any) => c.id);

        let accepted = null;
        if (chatIds.length > 0) {
          const { data } = await supabase
            .from("messages")
            .select("buyer_fee_amount, vendor_contribution, created_at")
            .in("chat_id", chatIds)
            .eq("delivery_fee_status", "accepted")
            .order("created_at", { ascending: false })
            .limit(1)
            .maybeSingle();
          accepted = data;
        }

        if (!accepted) {
          return err({
            error: "no_delivery_fee_agreed",
            message: "Please agree on a delivery fee with the vendor in chat before checkout.",
            vendor_id: vendorId,
          });
        }

        // Reject a stale negotiated fee so checkout never uses an out-of-date price.
        const feeValidMs =
          (await getNumber("delivery_fee_valid_minutes", "DELIVERY_FEE_VALID_MINUTES", DELIVERY_FEE_VALID_MINUTES_DEFAULT)) * 60_000;
        if (Date.now() - new Date(accepted.created_at).getTime() > feeValidMs) {
          return err({
            error: "delivery_fee_expired",
            message: "The delivery fee you agreed has expired. Please ask the vendor for a fresh delivery fee in chat.",
            vendor_id: vendorId,
          });
        }

        deliveryFee = Number(accepted.buyer_fee_amount) || 0;
        vendorContribution = Number(accepted.vendor_contribution) || 0;
        // Chat-agreed fee = vendor handles delivery. Mark 'negotiate' (not
        // courier) so the vendor keeps the fee and the fee gets consumed.
        deliveryType = "negotiate";
      }

      verifiedOrders.push({ vendorId, storeId: vendorOrder.store_id || "", items, subtotal, deliveryFee, deliveryType, vendorContribution, courierQuoteId, courierName, courierProvider });
      total += subtotal + deliveryFee;
    }

    if (verifiedOrders.length === 0) {
      return new Response(
        JSON.stringify({ error: "No valid vendor orders" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Atomic, race-safe deduction — fails (returns null) if balance < total.
    // This only supports credit fully covering the order; partial credit +
    // card combination is not built yet.
    const { data: spendResult, error: spendError } = await supabase.rpc("spend_kays_credit", {
      p_user_id: buyer_id,
      p_amount: total,
    });

    if (spendError || spendResult === null) {
      return new Response(
        JSON.stringify({ error: "Insufficient credit balance" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const createdOrders: any[] = [];
    let creationFailed = false;

    for (const vo of verifiedOrders) {
      // No commission at launch. Courier: platform pays the courier, so the fee
      // is NOT the vendor's. Free/negotiate: the vendor delivers and keeps it.
      const totalWithDelivery = vo.subtotal + vo.deliveryFee;
      const platformFee = 0;
      const vendorPayout = vo.deliveryType === "courier" ? vo.subtotal : totalWithDelivery;
      const orderId = crypto.randomUUID();
      const reference = `credit_${buyer_id.substring(0, 8)}_${Date.now()}`;
      const pickupDeadline = vo.deliveryType === "courier"
        ? new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString() : null;

      const { error: orderError } = await supabase.from("orders").insert({
        id: orderId,
        buyer_id,
        vendor_id: vo.vendorId,
        store_id: vo.storeId,
        status: "paid",
        paid_at: new Date().toISOString(),
        items: JSON.stringify(vo.items),
        total: vo.subtotal,
        delivery_fee: vo.deliveryFee,
        delivery_type: vo.deliveryType,
        vendor_delivery_contribution: vo.vendorContribution,
        total_with_delivery: totalWithDelivery,
        payment_reference: reference,
        delivery_quote_id: vo.courierQuoteId,
        selected_courier_name: vo.courierName,
        selected_provider: vo.courierProvider,
        pickup_deadline: pickupDeadline,
      });

      if (orderError) {
        console.error(`Failed to create credit order for vendor ${vo.vendorId}:`, orderError);
        creationFailed = true;
        break;
      }

      await supabase.from("transactions").insert({
        order_id: orderId,
        buyer_id,
        vendor_id: vo.vendorId,
        store_id: vo.storeId || null,
        amount: totalWithDelivery,
        platform_fee: platformFee,
        vendor_payout: vendorPayout,
        paystack_reference: reference,
        status: "success",
        type: "payment",
        metadata: JSON.stringify({ funding_source: "kays_credit", item_subtotal: vo.subtotal, delivery_fee: vo.deliveryFee }),
      });

      try {
        const { data: tokenData } = await supabase
          .from("device_tokens")
          .select("fcm_token")
          .eq("user_id", vo.vendorId)
          .maybeSingle();
        if (tokenData?.fcm_token) {
          await fetch(`${supabaseUrl}/functions/v1/send-push`, {
            method: "POST",
            headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
            body: JSON.stringify({
              user_id: vo.vendorId,
              title: "New Order!",
              body: `You received a new order of ₦${totalWithDelivery.toLocaleString()}`,
              data: { type: "order", orderId },
            }),
          });
        }
      } catch (pushErr) {
        console.error(`Failed to push vendor ${vo.vendorId}:`, pushErr);
      }

      // Consume the negotiated delivery fee so the next order re-negotiates.
      if (vo.deliveryType !== "courier" && Number(vo.deliveryFee) > 0) {
        try {
          const { data: chats } = await supabase.from("chats").select("id").eq("buyer_id", buyer_id).eq("vendor_id", vo.vendorId);
          const chatIds = (chats || []).map((c: any) => c.id);
          if (chatIds.length) {
            await supabase.from("messages").update({ delivery_fee_status: "used" }).in("chat_id", chatIds).eq("delivery_fee_status", "accepted");
          }
        } catch (_) { /* non-fatal */ }
      }

      createdOrders.push({ id: orderId, vendorId: vo.vendorId, subtotal: vo.subtotal });
    }

    if (creationFailed) {
      // Compensating rollback — refund the full deducted credit since not
      // every vendor's order could be created. Buyer should not lose
      // credit for a purchase that didn't fully go through.
      const { error: refundError } = await supabase.rpc("increment_kays_credit", {
        p_user_id: buyer_id,
        p_amount: total,
      });
      if (refundError) {
        const { data: user } = await supabase.from("users").select("kays_credit").eq("id", buyer_id).maybeSingle();
        const currentCredit = user?.kays_credit || 0;
        await supabase.from("users").update({ kays_credit: currentCredit + total }).eq("id", buyer_id);
      }
      return new Response(
        JSON.stringify({ error: "Order creation failed — credit has been refunded, please try again" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    await supabase.from("credit_transactions").insert({
      buyer_id,
      amount: -total,
      type: "used",
      order_id: createdOrders.map((o) => o.id).join(","),
      description: "Used for order payment",
    });

    try {
      await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          user_id: buyer_id,
          title: "Order Complete!",
          body: `Paid ₦${total.toLocaleString()} with Kay's Credit. ${createdOrders.length} order(s) confirmed.`,
          data: { type: "order" },
        }),
      });
    } catch (pushErr) {
      console.error("Failed to push buyer:", pushErr);
    }

    // Clear only the items actually checked out (so a single-item "Buy Now"
    // leaves the rest of the cart intact). Full-cart checkout clears all — same
    // as before.
    try {
      const boughtIds = [...new Set(vendor_orders.flatMap((vo: any) => (vo.items || []).map((it: any) => it.product_id)).filter(Boolean))] as string[];
      await supabase.from("cart_items").delete().eq("buyer_id", buyer_id).in("product_id", boughtIds);
    } catch (cartErr) {
      console.error("Failed to clear cart:", cartErr);
    }

    return new Response(
      JSON.stringify({ success: true, orders: createdOrders, total_paid: total }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: any) {
    console.error("complete-credit-order error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
