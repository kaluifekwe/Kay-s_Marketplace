import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const paystackSecretKey = Deno.env.get("PAYSTACK_SECRET_KEY")!;

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

    const { order_id, buyer_id, vendor_orders, amount, email } = await req.json();

    if (!order_id || !buyer_id || !vendor_orders || !Array.isArray(vendor_orders) || vendor_orders.length === 0 || !amount || !email) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: order_id, buyer_id, vendor_orders, amount, email" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!callerId || callerId !== buyer_id) {
      return new Response(
        JSON.stringify({ error: "Authenticated user does not match buyer_id" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (typeof amount !== "number" || amount <= 0 || amount > 50000000) {
      return new Response(
        JSON.stringify({ error: "Invalid amount" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Buyers are NOT identity-gated to buy (only vendors, and buyers withdrawing
    // to a bank, verify). We still enforce the intrastate rule, which needs the
    // buyer's state.
    const { data: buyerRow, error: buyerErr } = await supabase
      .from("users")
      .select("state")
      .eq("id", buyer_id)
      .maybeSingle();

    if (buyerErr || !buyerRow?.state) {
      return new Response(
        JSON.stringify({ error: "Buyer state not set. Please update your profile state." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const vendorIds = [...new Set(vendor_orders.map((v: any) => v.vendor_id).filter(Boolean))];
    const { data: vendorRows, error: vendorErr } = await supabase
      .from("users")
      .select("id, state")
      .in("id", vendorIds);

    if (vendorErr) {
      return new Response(
        JSON.stringify({ error: "Failed to verify vendor states" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const mismatched = (vendorRows || []).filter((v: any) => v.state !== buyerRow.state);
    if (mismatched.length > 0) {
      return new Response(
        JSON.stringify({
          error: "Cross-state purchase blocked: one or more vendors are not in your state",
          code: "INTRASTATE_BLOCK",
        }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Verify each vendor's delivery fee server-side — never trust the
    // client-supplied delivery_fee. The bug this fixes: buyers were never
    // actually charged for delivery fees agreed in chat, even though
    // vendors expected to receive them. Item prices are still verified
    // later by the webhook (which already recomputes them from the
    // products table); here we only need to resolve delivery fee, since
    // chat-acceptance (not product price) is its source of truth.
    const enrichedVendorOrders: any[] = [];
    let serverAmount = 0;

    for (const vendorOrder of vendor_orders) {
      const vendorId = vendorOrder.vendor_id;
      const items = vendorOrder.items || [];

      // SECURITY: derive the item subtotal from the DB — NEVER trust the
      // client's `subtotal`/`amount` (a tampered client could pay ₦1 for a
      // ₦950k item). Each item's unit price is the product's price, or the
      // matching variant's price when a variant was chosen.
      let itemSubtotal = 0;
      for (const it of items) {
        const pid = it.product_id;
        const qty = Number(it.quantity) || 0;
        if (!pid || qty <= 0) {
          return new Response(
            JSON.stringify({ error: "Invalid cart item" }),
            { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
        const { data: prod } = await supabase
          .from("products")
          .select("price")
          .eq("id", pid)
          .maybeSingle();
        if (!prod) {
          return new Response(
            JSON.stringify({ error: "Product not found" }),
            { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
        let unitPrice = Number(prod.price) || 0;
        if (it.variant_label) {
          const { data: variant } = await supabase
            .from("product_variants")
            .select("price")
            .eq("product_id", pid)
            .eq("label", it.variant_label)
            .maybeSingle();
          if (!variant) {
            return new Response(
              JSON.stringify({ error: "Product option not found" }),
              { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
            );
          }
          unitPrice = Number(variant.price) || 0;
        }
        itemSubtotal += unitPrice * qty;
      }

      const firstProductId = items[0]?.product_id;

      let deliveryType = "negotiate";
      if (firstProductId) {
        const { data: product } = await supabase
          .from("products")
          .select("delivery_type")
          .eq("id", firstProductId)
          .maybeSingle();
        deliveryType = product?.delivery_type || "negotiate";
      }

      let verifiedDeliveryFee = 0;
      let vendorContribution = 0;
      let courierQuoteId: string | null = null;
      let courierName: string | null = null;
      let courierOptionRef: string | null = null;
      let courierProvider: string | null = null;

      // Buyer chose a Shipbubble courier at checkout. The fee is verified
      // from the stored quote (never the client), and the quote id + courier
      // are threaded through so paystack-webhook can auto-book after payment.
      if (vendorOrder.delivery_quote_id && vendorOrder.selected_courier_name) {
        const { data: quote } = await supabase
          .from("delivery_quotes")
          .select("available_couriers, expires_at, buyer_id, vendor_id")
          .eq("id", vendorOrder.delivery_quote_id)
          .maybeSingle();

        if (!quote || quote.buyer_id !== buyer_id || quote.vendor_id !== vendorId) {
          return new Response(
            JSON.stringify({ error: "invalid_quote", message: "Delivery quote not found for this order.", vendor_id: vendorId }),
            { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
        if (quote.expires_at && new Date(quote.expires_at) < new Date()) {
          return new Response(
            JSON.stringify({ error: "quote_expired", message: "Your delivery quote expired. Please refresh delivery options.", vendor_id: vendorId }),
            { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
        // Merged multi-provider shape: couriers carry { provider, optionRef, name, fee }.
        const couriers = quote.available_couriers?.couriers || [];
        const selected = couriers.find((c: any) =>
          vendorOrder.selected_option_ref ? c.optionRef === vendorOrder.selected_option_ref : c.name === vendorOrder.selected_courier_name
        );
        if (!selected) {
          return new Response(
            JSON.stringify({ error: "courier_unavailable", message: "Selected courier is no longer available.", vendor_id: vendorId }),
            { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
        verifiedDeliveryFee = Number(selected.fee) || 0;
        deliveryType = "courier";
        courierQuoteId = vendorOrder.delivery_quote_id;
        courierName = selected.name;
        courierOptionRef = selected.optionRef;
        courierProvider = selected.provider;
      } else if (deliveryType === "negotiate" || deliveryType === "split") {
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
            .select("buyer_fee_amount, vendor_contribution")
            .in("chat_id", chatIds)
            .eq("delivery_fee_status", "accepted")
            .order("created_at", { ascending: false })
            .limit(1)
            .maybeSingle();
          accepted = data;
        }

        if (!accepted) {
          return new Response(
            JSON.stringify({
              error: "no_delivery_fee_agreed",
              message: "Please agree on a delivery fee with the vendor in chat before checkout.",
              vendor_id: vendorId,
            }),
            { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }

        verifiedDeliveryFee = Number(accepted.buyer_fee_amount) || 0;
        vendorContribution = Number(accepted.vendor_contribution) || 0;
      }

      enrichedVendorOrders.push({
        ...vendorOrder,
        delivery_fee: verifiedDeliveryFee,
        delivery_type: deliveryType,
        vendor_contribution: vendorContribution,
        delivery_quote_id: courierQuoteId,
        selected_courier_name: courierName,
        selected_option_ref: courierOptionRef,
        selected_provider: courierProvider,
      });
      serverAmount += itemSubtotal + verifiedDeliveryFee;
    }

    if (serverAmount <= 0 || serverAmount > 50000000) {
      return new Response(
        JSON.stringify({ error: "Invalid amount" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const amountKobo = Math.round(serverAmount * 100);

    const paystackResponse = await fetch("https://api.paystack.co/transaction/initialize", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${paystackSecretKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        email,
        amount: amountKobo,
        currency: "NGN",
        reference: order_id,
        metadata: {
          order_id,
          buyer_id,
          vendor_orders: enrichedVendorOrders,
          total: serverAmount,
          custom_fields: [
            {
              display_name: "Order ID",
              variable_name: "order_id",
              value: order_id,
            },
          ],
        },
      }),
    });

    const paystackData = await paystackResponse.json();

    if (!paystackData.status) {
      console.error("Paystack init error:", paystackData);
      return new Response(
        JSON.stringify({ error: paystackData.message || "Failed to initialize payment" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Store transaction record for first vendor (primary). order_id is NOT
    // set here — transactions.order_id has a foreign key to orders.id, but
    // the real per-vendor order rows don't exist yet at this point (they're
    // only created later, by the webhook, after payment succeeds). Setting
    // it to the not-yet-existing order_id always violated that FK and made
    // this insert fail silently (txError was only logged, never surfaced).
    // The webhook looks this row up by paystack_reference, not order_id.
    const firstVendor = enrichedVendorOrders[0];
    const { error: txError } = await supabase.from("transactions").upsert(
      {
        buyer_id,
        vendor_id: firstVendor.vendor_id,
        store_id: firstVendor.store_id || null,
        amount: serverAmount,
        paystack_reference: order_id,
        paystack_access_code: paystackData.data.access_code,
        paystack_authorization_url: paystackData.data.authorization_url,
        status: "pending",
        type: "payment",
        metadata: JSON.stringify(enrichedVendorOrders),
      },
      { onConflict: "paystack_reference" }
    );

    if (txError) {
      console.error("Transaction save error:", txError);
    }

    return new Response(
      JSON.stringify({
        success: true,
        authorization_url: paystackData.data.authorization_url,
        access_code: paystackData.data.access_code,
        reference: paystackData.data.reference,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: any) {
    console.error("Edge function error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
