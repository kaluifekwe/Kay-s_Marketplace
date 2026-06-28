import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const paystackSecretKey = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const paystackWebhookSecret = Deno.env.get("PAYSTACK_WEBHOOK_SECRET") || paystackSecretKey;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Uses Deno's built-in Web Crypto API (no extra import needed) to compute
// the HMAC-SHA512 signature Paystack sends, and compares it to what they
// actually sent.
async function verifyWebhookSignature(payload: string, signature: string): Promise<boolean> {
  try {
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      encoder.encode(paystackWebhookSecret),
      { name: "HMAC", hash: "SHA-512" },
      false,
      ["sign"]
    );
    const sigBuffer = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
    const expected = Array.from(new Uint8Array(sigBuffer))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    if (expected.length !== signature.length) return false;
    let mismatch = 0;
    for (let i = 0; i < expected.length; i++) {
      mismatch |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
    }
    return mismatch === 0;
  } catch {
    return false;
  }
}

async function processPayment(supabase: any, reference: string, eventId?: string, paidAt?: string, paidAmountKobo?: number) {
  // Idempotency: check if orders already exist for this payment reference
  const { data: existingOrders } = await supabase
    .from("orders")
    .select("id")
    .eq("payment_reference", reference);

  if (existingOrders && existingOrders.length > 0) {
    console.log(`Orders already exist for ref: ${reference} (${existingOrders.length} orders)`);
    return { alreadyProcessed: true, orderCount: existingOrders.length };
  }

  // Get transaction metadata (vendor_orders stored during create-payment)
  const { data: tx } = await supabase
    .from("transactions")
    .select("id, status, metadata, buyer_id, vendor_id, amount")
    .eq("paystack_reference", reference)
    .maybeSingle();

  let vendorOrders: any[] = [];
  let buyerId = "";
  let totalAmount = 0;

  if (tx && tx.metadata) {
    try {
      const parsed = typeof tx.metadata === "string" ? JSON.parse(tx.metadata) : tx.metadata;
      // metadata might be the vendor_orders array directly, or an object containing it
      if (Array.isArray(parsed)) {
        vendorOrders = parsed;
      } else if (parsed.vendor_orders) {
        vendorOrders = parsed.vendor_orders;
      }
    } catch (e) {
      console.error("Failed to parse transaction metadata:", e);
    }
    buyerId = tx.buyer_id || "";
    totalAmount = tx.amount || 0;
  }

  if (vendorOrders.length === 0) {
    console.error(`No vendor_orders found for ref: ${reference}`);
    return { alreadyProcessed: false, orderCount: 0, error: "No vendor_orders in metadata" };
  }

  // Update transaction status to success
  await supabase
    .from("transactions")
    .update({
      status: "success",
      metadata: JSON.stringify({
        ...(tx?.metadata ? (typeof tx.metadata === "string" ? JSON.parse(tx.metadata) : tx.metadata) : {}),
        paystack_event_id: eventId || null,
        paystack_paid_at: paidAt || new Date().toISOString(),
      }),
    })
    .eq("paystack_reference", reference);

  // Recompute every vendor order's subtotal from real product/variant
  // prices instead of trusting the client-supplied amount — a modified
  // client could otherwise pay for cheap items but claim a different
  // (or larger) cart, causing orders to be created for goods never paid for.
  //
  // Delivery fee/type are NOT re-derived here from chat — they were already
  // verified server-side by create-payment (against the accepted chat
  // message) and written into this transaction's metadata, which the client
  // cannot modify after the fact. We just read them back as trusted values.
  const verifiedSubtotals = new Map<number, number>();
  let recomputedTotal = 0;
  for (let i = 0; i < vendorOrders.length; i++) {
    const vendorOrder = vendorOrders[i];
    const items = vendorOrder.items || [];
    if (!vendorOrder.vendor_id) continue;

    const productIds = [...new Set(items.map((it: any) => it.product_id).filter(Boolean))];
    const { data: products } = productIds.length
      ? await supabase.from("products").select("id, price").in("id", productIds)
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

    if (!priceMismatch) {
      verifiedSubtotals.set(i, subtotal);
      const deliveryFee = Number(vendorOrder.delivery_fee) || 0;
      recomputedTotal += subtotal + deliveryFee;
    }
  }

  // If Paystack told us (in the signed webhook body) what was actually
  // charged, it must match the real cart value within a 1-naira rounding
  // tolerance, or we refuse to create any orders for this payment.
  if (paidAmountKobo !== undefined) {
    const paidNaira = paidAmountKobo / 100;
    if (Math.abs(paidNaira - recomputedTotal) > 1) {
      console.error(
        `Amount mismatch for ref ${reference}: paid=${paidNaira}, recomputed cart total=${recomputedTotal}`
      );
      return { alreadyProcessed: false, orderCount: 0, error: "Paid amount does not match cart total" };
    }
  }

  const createdOrders: any[] = [];

  // Create separate order for each vendor
  for (let i = 0; i < vendorOrders.length; i++) {
    const vendorOrder = vendorOrders[i];
    const vendorId = vendorOrder.vendor_id;
    const storeId = vendorOrder.store_id || "";
    const items = vendorOrder.items || [];

    if (!vendorId) {
      console.error(`Skipping vendor order with no vendor_id:`, vendorOrder);
      continue;
    }

    const subtotal = verifiedSubtotals.get(i);
    if (subtotal === undefined) {
      console.error(`Skipping vendor order ${vendorId}: could not verify all item prices`, vendorOrder);
      continue;
    }

    // orders.id is a uuid column — must be a real UUID, not the old
    // "${reference}_${vendorId}_${timestamp}" string this used to build,
    // which always failed the insert with "invalid input syntax for type
    // uuid" (silently caught below, leaving orderCount stuck at 0).
    const vendorOrderId = crypto.randomUUID();

    // No commission at launch — vendor receives 100% of item price plus
    // the full delivery fee. deliveryFee/deliveryType were already verified
    // server-side by create-payment against the accepted chat message.
    const deliveryFee = Number(vendorOrder.delivery_fee) || 0;
    const deliveryType = vendorOrder.delivery_type || null;
    const vendorContribution = Number(vendorOrder.vendor_contribution) || 0;
    const courierQuoteId = vendorOrder.delivery_quote_id || null;
    const courierName = vendorOrder.selected_courier_name || null;
    const courierOptionRef = vendorOrder.selected_option_ref || null;
    const totalWithDelivery = subtotal + deliveryFee;
    const platformFee = 0;
    const vendorPayout = totalWithDelivery;

    // Insert order for this vendor
    const { error: orderError } = await supabase.from("orders").insert({
      id: vendorOrderId,
      buyer_id: buyerId,
      vendor_id: vendorId,
      store_id: storeId,
      status: "paid",
      paid_at: new Date().toISOString(),
      items: JSON.stringify(items),
      total: subtotal,
      delivery_fee: deliveryFee,
      delivery_type: deliveryType,
      vendor_delivery_contribution: vendorContribution,
      total_with_delivery: totalWithDelivery,
      payment_reference: reference,
    });

    if (orderError) {
      console.error(`Failed to create order for vendor ${vendorId}:`, orderError);
      continue;
    }

    // Create transaction record for this vendor's order
    await supabase.from("transactions").insert({
      order_id: vendorOrderId,
      buyer_id: buyerId,
      vendor_id: vendorId,
      store_id: storeId || null,
      amount: totalWithDelivery,
      platform_fee: platformFee,
      vendor_payout: vendorPayout,
      paystack_reference: `tx_${vendorOrderId}`,
      status: "success",
      type: "payment",
      metadata: JSON.stringify({
        paystack_event_id: eventId || null,
        paystack_paid_at: paidAt || new Date().toISOString(),
        item_subtotal: subtotal,
        delivery_fee: deliveryFee,
        delivery_type: deliveryType,
      }),
    });

    // Send push notification to vendor
    try {
      const { data: tokenData } = await supabase
        .from("device_tokens")
        .select("fcm_token")
        .eq("user_id", vendorId)
        .maybeSingle();

      if (tokenData?.fcm_token) {
        // Send via send-push Edge Function
        await fetch(`${supabaseUrl}/functions/v1/send-push`, {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${supabaseServiceKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            user_id: vendorId,
            title: "New Order!",
            body: `You received a new order of \u20A6${totalWithDelivery.toLocaleString()}`,
            data: { type: "order", orderId: vendorOrderId },
          }),
        });
        console.log(`Push sent to vendor ${vendorId}`);
      }
    } catch (pushErr) {
      console.error(`Failed to push vendor ${vendorId}:`, pushErr);
    }

    // Courier order: auto-book Shipbubble now while the checkout quote is
    // still fresh. The delivery fee is already in escrow; book-delivery pays
    // Shipbubble from the platform wallet. If booking fails (wallet low,
    // courier gone), the order still stands — it just has no courier yet and
    // admin/vendor can sort it out; we don't want to fail a paid order here.
    if (courierQuoteId && courierName) {
      try {
        const bookRes = await fetch(`${supabaseUrl}/functions/v1/book-delivery`, {
          method: "POST",
          headers: { Authorization: `Bearer ${supabaseServiceKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            order_id: vendorOrderId,
            quote_id: courierQuoteId,
            selected_courier_name: courierName,
            selected_option_ref: courierOptionRef,
            vendor_id: vendorId,
          }),
        });
        if (!bookRes.ok) {
          console.error(`Courier auto-book failed for order ${vendorOrderId}:`, await bookRes.text());
        }
      } catch (bookErr) {
        console.error(`Courier auto-book threw for order ${vendorOrderId}:`, bookErr);
      }
    }

    createdOrders.push({ id: vendorOrderId, vendorId, subtotal });
    console.log(`Order created: ${vendorOrderId}, vendor: ${vendorId}, subtotal: ${subtotal}`);
  }

  // Send push notification to buyer
  if (buyerId && createdOrders.length > 0) {
    try {
      await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${supabaseServiceKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: buyerId,
          title: "Payment Confirmed!",
          body: `Your payment of \u20A6${totalAmount.toLocaleString()} was successful. ${createdOrders.length} order(s) confirmed.`,
          data: { type: "order", orderId: reference },
        }),
      });
    } catch (pushErr) {
      console.error("Failed to push buyer:", pushErr);
    }
  }

  // Clear buyer's cart
  if (buyerId) {
    try {
      await supabase
        .from("cart_items")
        .delete()
        .eq("buyer_id", buyerId);
      console.log(`Cart cleared for buyer ${buyerId}`);
    } catch (cartErr) {
      console.error("Failed to clear cart:", cartErr);
    }
  }

  return { alreadyProcessed: false, orderCount: createdOrders.length, orders: createdOrders };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // HANDLE GET REQUEST (Paystack redirect from webview)
    if (req.method === "GET") {
      const url = new URL(req.url);
      const reference = url.searchParams.get("trxref") || url.searchParams.get("reference") || "";

      console.log(`GET redirect with reference: ${reference}`);

      // This redirect just means the buyer's webview navigated back to us —
      // it is NOT proof that payment succeeded. Verify directly with
      // Paystack before creating any orders.
      if (reference) {
        try {
          const verifyRes = await fetch(
            `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
            { headers: { Authorization: `Bearer ${paystackSecretKey}` } }
          );
          const verifyData = await verifyRes.json();
          if (verifyData.status && verifyData.data?.status === "success") {
            const result = await processPayment(
              supabase,
              reference,
              verifyData.data.id,
              verifyData.data.paid_at,
              verifyData.data.amount
            );
            console.log(`GET process result:`, result);
          } else {
            console.log(`GET redirect: payment not confirmed for ref ${reference}`);
          }
        } catch (e) {
          console.error("GET verify error:", e);
        }
      }

      // Return a simple HTML page that communicates with the app
      return new Response(
        `<!DOCTYPE html><html><body><script>
          window.location = "https://paystack.com/success?trxref=${reference}&reference=${reference}";
        </script></body></html>`,
        { status: 200, headers: { "Content-Type": "text/html" } }
      );
    }

    // HANDLE POST REQUEST (Paystack webhook)
    if (req.method !== "POST") {
      return new Response(JSON.stringify({ error: "Method not allowed" }), {
        status: 405,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const signature = req.headers.get("x-paystack-signature") || "";
    const rawBody = await req.text();

    // Signature is mandatory — Paystack always sends it on real webhook calls.
    if (!signature || !(await verifyWebhookSignature(rawBody, signature))) {
      console.error("Missing or invalid webhook signature");
      return new Response(
        JSON.stringify({ error: "Invalid signature" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const event = JSON.parse(rawBody);

    if (event.event === "charge.success") {
      const reference = event.data.reference;
      const eventId = event.id;
      const paidAt = event.data.paid_at;

      console.log(`Webhook charge.success: ref=${reference}, event=${eventId}`);

      const result = await processPayment(supabase, reference, eventId, paidAt, event.data.amount);
      console.log(`Webhook process result:`, JSON.stringify(result));
    }

    return new Response(
      JSON.stringify({ success: true }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: any) {
    console.error("Webhook error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
