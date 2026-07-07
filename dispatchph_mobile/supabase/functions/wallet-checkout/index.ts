import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Pay for a checkout entirely from the buyer's WALLET balance. This is the
// provider-agnostic core of the wallet system: it never talks to any payment
// provider — it just moves internal ledger balance (wallet_debit) and creates
// the per-vendor orders + escrow records, exactly like a card/credit order.
// The vendor is paid on delivery by release-escrow crediting their wallet.
//
// Mirrors create-payment's server-side verification (KYC, intrastate, real
// prices, delivery fee/courier) and paystack-webhook's order creation, so a
// wallet-paid order is identical to a card-paid one from here on.

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
    const { buyer_id, vendor_orders } = await req.json();

    if (!buyer_id || !Array.isArray(vendor_orders) || vendor_orders.length === 0) {
      return json({ error: "Missing required fields: buyer_id, vendor_orders" }, 400);
    }
    if (!callerId || callerId !== buyer_id) {
      return json({ error: "Authenticated user does not match buyer_id" }, 403);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // KYC + state gates (mirror create-payment).
    const { data: buyerRow } = await supabase
      .from("users")
      .select("state, kyc_status")
      .eq("id", buyer_id)
      .maybeSingle();
    if (buyerRow?.kyc_status !== "verified") {
      return json({ error: "kyc_required", message: "Verify your identity (NIN) before buying." }, 403);
    }
    if (!buyerRow?.state) {
      return json({ error: "Buyer state not set. Please update your profile state." }, 400);
    }

    // Intrastate: all vendors must be in the buyer's state.
    const vendorIds = [...new Set(vendor_orders.map((v: any) => v.vendor_id).filter(Boolean))];
    const { data: vendorRows } = await supabase.from("users").select("id, state").in("id", vendorIds);
    const mismatched = (vendorRows || []).filter((v: any) => v.state !== buyerRow.state);
    if (mismatched.length > 0) {
      return json({ error: "Cross-state purchase blocked: one or more vendors are not in your state", code: "INTRASTATE_BLOCK" }, 403);
    }

    // Verify each vendor order server-side (prices from DB, delivery fee from
    // the stored quote or accepted chat message — never the client).
    const enriched: any[] = [];
    let total = 0;

    for (const vo of vendor_orders) {
      const vendorId = vo.vendor_id;
      const items = vo.items || [];
      if (!vendorId || items.length === 0) continue;

      let itemSubtotal = 0;
      for (const it of items) {
        const pid = it.product_id;
        const qty = Number(it.quantity) || 0;
        if (!pid || qty <= 0) return json({ error: "Invalid cart item" }, 400);
        const { data: prod } = await supabase.from("products").select("price, delivery_type").eq("id", pid).maybeSingle();
        if (!prod) return json({ error: "Product not found" }, 400);
        let unitPrice = Number(prod.price) || 0;
        if (it.variant_label) {
          const { data: variant } = await supabase
            .from("product_variants").select("price").eq("product_id", pid).eq("label", it.variant_label).maybeSingle();
          if (!variant) return json({ error: "Product option not found" }, 400);
          unitPrice = Number(variant.price) || 0;
        }
        itemSubtotal += unitPrice * qty;
      }

      const { data: firstProd } = await supabase
        .from("products").select("delivery_type").eq("id", items[0]?.product_id).maybeSingle();
      let deliveryType = firstProd?.delivery_type || "negotiate";
      let deliveryFee = 0;
      let vendorContribution = 0;
      let courierQuoteId: string | null = null;
      let courierName: string | null = null;
      let courierOptionRef: string | null = null;
      let courierProvider: string | null = null;

      if (vo.delivery_quote_id && vo.selected_courier_name) {
        const { data: quote } = await supabase
          .from("delivery_quotes")
          .select("available_couriers, expires_at, buyer_id, vendor_id")
          .eq("id", vo.delivery_quote_id)
          .maybeSingle();
        if (!quote || quote.buyer_id !== buyer_id || quote.vendor_id !== vendorId) {
          return json({ error: "invalid_quote", message: "Delivery quote not found for this order.", vendor_id: vendorId }, 400);
        }
        if (quote.expires_at && new Date(quote.expires_at) < new Date()) {
          return json({ error: "quote_expired", message: "Your delivery quote expired. Please refresh delivery options.", vendor_id: vendorId }, 400);
        }
        const couriers = quote.available_couriers?.couriers || [];
        const selected = couriers.find((c: any) =>
          vo.selected_option_ref ? c.optionRef === vo.selected_option_ref : c.name === vo.selected_courier_name
        );
        if (!selected) {
          return json({ error: "courier_unavailable", message: "Selected courier is no longer available.", vendor_id: vendorId }, 400);
        }
        deliveryFee = Number(selected.fee) || 0;
        deliveryType = "courier";
        courierQuoteId = vo.delivery_quote_id;
        courierName = selected.name;
        courierOptionRef = selected.optionRef;
        courierProvider = selected.provider;
      } else if (deliveryType === "negotiate" || deliveryType === "split") {
        const { data: chats } = await supabase.from("chats").select("id").eq("buyer_id", buyer_id).eq("vendor_id", vendorId);
        const chatIds = (chats || []).map((c: any) => c.id);
        let accepted = null;
        if (chatIds.length > 0) {
          const { data } = await supabase
            .from("messages")
            .select("buyer_fee_amount, vendor_contribution")
            .in("chat_id", chatIds)
            .eq("delivery_fee_status", "accepted")
            .order("created_at", { ascending: false })
            .limit(1)
            .maybeSingle();
          accepted = data;
        }
        if (!accepted) {
          return json({ error: "no_delivery_fee_agreed", message: "Please agree on a delivery fee with the vendor in chat before checkout.", vendor_id: vendorId }, 400);
        }
        deliveryFee = Number(accepted.buyer_fee_amount) || 0;
        vendorContribution = Number(accepted.vendor_contribution) || 0;
      }

      enriched.push({
        vendorId, storeId: vo.store_id || "", items, subtotal: itemSubtotal,
        deliveryFee, deliveryType, vendorContribution,
        courierQuoteId, courierName, courierOptionRef, courierProvider,
      });
      total += itemSubtotal + deliveryFee;
    }

    if (enriched.length === 0) return json({ error: "No valid vendor orders" }, 400);
    if (total <= 0 || total > 50000000) return json({ error: "Invalid amount" }, 400);

    // Atomic, race-safe wallet debit. Fails (null) if balance < total — in which
    // case report the shortfall so the app can prompt "Add money".
    const debitRef = `wchk${buyer_id.replace(/-/g, "")}${Date.now().toString(36)}`.slice(0, 42);
    const { data: newBalance, error: debitErr } = await supabase.rpc("wallet_debit", {
      p_user_id: buyer_id,
      p_amount: total,
      p_type: "purchase",
      p_reference: debitRef,
      p_description: "Order payment",
    });
    if (debitErr) {
      console.error("wallet_debit error:", debitErr);
      return json({ error: "Wallet debit failed" }, 500);
    }
    if (newBalance === null) {
      const { data: w } = await supabase.from("wallets").select("balance").eq("user_id", buyer_id).maybeSingle();
      const balance = Number(w?.balance ?? 0);
      return json({ error: "insufficient_balance", message: "Your wallet balance is too low.", balance, required: total, shortfall: Math.max(0, total - balance) }, 402);
    }

    // Create one order per vendor (mirrors paystack-webhook).
    const createdOrders: any[] = [];
    let creationFailed = false;
    const PICKUP_WINDOW_HOURS = 24;

    for (const vo of enriched) {
      const totalWithDelivery = vo.subtotal + vo.deliveryFee;
      // Courier: platform pays the courier, so the fee is NOT paid to the vendor.
      // Free/negotiate: the vendor delivers and keeps the fee.
      const vendorPayout = vo.deliveryType === "courier" ? vo.subtotal : totalWithDelivery;
      const orderId = crypto.randomUUID();
      const reference = `wallet_${orderId}`;
      const pickupDeadline = vo.deliveryType === "courier"
        ? new Date(Date.now() + PICKUP_WINDOW_HOURS * 60 * 60 * 1000).toISOString() : null;

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
        console.error(`Failed to create wallet order for vendor ${vo.vendorId}:`, orderError);
        creationFailed = true;
        break;
      }

      await supabase.from("transactions").insert({
        order_id: orderId,
        buyer_id,
        vendor_id: vo.vendorId,
        store_id: vo.storeId || null,
        amount: totalWithDelivery,
        platform_fee: 0,
        vendor_payout: vendorPayout,
        paystack_reference: `tx_${orderId}`,
        status: "success",
        type: "payment",
        metadata: JSON.stringify({ funding_source: "wallet", item_subtotal: vo.subtotal, delivery_fee: vo.deliveryFee, delivery_type: vo.deliveryType }),
      });

      try {
        const { data: tokenData } = await supabase.from("device_tokens").select("fcm_token").eq("user_id", vo.vendorId).maybeSingle();
        if (tokenData?.fcm_token) {
          await fetch(`${supabaseUrl}/functions/v1/send-push`, {
            method: "POST",
            headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
            body: JSON.stringify({ user_id: vo.vendorId, title: "New Order!", body: `You received a new order of ₦${totalWithDelivery.toLocaleString()}`, data: { type: "order", orderId } }),
          });
        }
      } catch (_) { /* non-fatal */ }

      createdOrders.push({ id: orderId, vendorId: vo.vendorId, subtotal: vo.subtotal });
    }

    if (creationFailed) {
      // Compensating reversal — the buyer must not lose wallet money for a
      // purchase that didn't fully go through.
      await supabase.rpc("wallet_credit", {
        p_user_id: buyer_id,
        p_amount: total,
        p_type: "reversal",
        p_reference: `rev_${debitRef}`,
        p_description: "Reversal: order creation failed",
      });
      return json({ error: "Order creation failed — your wallet has been refunded, please try again" }, 500);
    }

    try { await supabase.from("cart_items").delete().eq("buyer_id", buyer_id); } catch (_) { /* non-fatal */ }
    try {
      await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ user_id: buyer_id, title: "Order Confirmed!", body: `Paid ₦${total.toLocaleString()} from your wallet. ${createdOrders.length} order(s) confirmed.`, data: { type: "order" } }),
      });
    } catch (_) { /* non-fatal */ }

    return json({ success: true, orders: createdOrders, total_paid: total, balance: newBalance });
  } catch (error: any) {
    console.error("wallet-checkout error:", error);
    return json({ error: error.message }, 500);
  }
});
