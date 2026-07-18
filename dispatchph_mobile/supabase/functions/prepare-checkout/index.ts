import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getNumber } from "../_shared/settings.ts";

// Prepare a Flutterwave buyer checkout. Verifies the order SERVER-SIDE (item
// prices + delivery fees re-derived from the DB — never the client, no NIN/BVN
// gate), stores a PENDING intent keyed by tx_ref, then creates a Flutterwave
// hosted payment LINK (card + bank transfer + USSD). The app opens that link in
// a webview (like the Paystack flow); flutterwave-webhook creates the real
// orders on `charge.completed`. Returns { link, tx_ref, amount }.
//
// Uses Flutterwave v3 collections (FLUTTERWAVE_SECRET_KEY / FLWSECK) for the
// hosted checkout — v4 has no hosted page. Payouts/VAs stay on v4; the webhook
// handles both.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
// A chat-negotiated delivery fee is valid for this long (from the vendor's offer)
// before checkout must use a freshly re-quoted fee.
// Tunable in the admin console (app_settings); literal stays as the fallback.
const DELIVERY_FEE_VALID_MINUTES_DEFAULT = 60;
// Public key (FLWPUBK-…) for the inline checkout SDK — safe to expose to the app.
const flwPublicKey = Deno.env.get("FLUTTERWAVE_PUBLIC_KEY") || "";
// Where Flutterwave redirects after payment. The webview only needs to RECOGNISE
// this URL to detect completion — the page itself need not exist.
const redirectUrl = Deno.env.get("FLW_REDIRECT_URL") || "https://kaysmarket-legal.web.app/payment-complete";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

function callerId(authHeader: string | null): string | null {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return null;
  const token = authHeader.replace("Bearer ", "");
  if (!token || token === supabaseAnonKey) return null;
  try {
    const p = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    if (p.exp && p.exp < Math.floor(Date.now() / 1000)) return null;
    return p.sub || null;
  } catch {
    return null;
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const uid = callerId(req.headers.get("Authorization"));
    const { buyer_id, vendor_orders, payment_option } = await req.json();
    // Optional: the buyer already picked a method in-app, so open Flutterwave
    // straight to it. Whitelisted to valid Flutterwave tokens; anything else is
    // ignored (Flutterwave then shows all enabled methods).
    const VALID_PAYMENT_OPTIONS = ["card", "banktransfer", "ussd", "account", "enaira", "qr", "nqr"];
    const chosenOption = typeof payment_option === "string" && VALID_PAYMENT_OPTIONS.includes(payment_option)
      ? payment_option
      : "";

    if (!buyer_id || !Array.isArray(vendor_orders) || vendor_orders.length === 0) {
      return json({ error: "Missing required fields: buyer_id, vendor_orders" }, 400);
    }
    if (!uid || uid !== buyer_id) return json({ error: "Authenticated user does not match buyer_id" }, 403);
    if (!flwPublicKey) return json({ error: "Payments are not configured yet." }, 500);

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Buyers are NOT identity-gated to buy. We still enforce the intrastate rule
    // (a business constraint, not KYC) and need the buyer's state + email.
    const { data: buyer } = await supabase
      .from("users")
      .select("state, email, name, phone")
      .eq("id", buyer_id)
      .maybeSingle();
    if (!buyer?.email) return json({ error: "no_email", message: "Add an email to your profile before checking out." }, 400);
    if (!buyer?.state) return json({ error: "no_state", message: "Set your state in your profile before checking out." }, 400);

    const vendorIds = [...new Set(vendor_orders.map((v: any) => v.vendor_id).filter(Boolean))];
    const { data: vendorRows } = await supabase.from("users").select("id, state").in("id", vendorIds);
    const mismatched = (vendorRows || []).filter((v: any) => v.state !== buyer.state);
    if (mismatched.length > 0) {
      return json({ error: "intrastate_only", message: "Cross-state purchase blocked: one or more vendors are not in your state", code: "INTRASTATE_BLOCK" }, 403);
    }

    // Re-derive prices + delivery from the DB (never the client) — identical to
    // create-payment / wallet-checkout.
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

      const { data: firstProd } = await supabase.from("products").select("delivery_type").eq("id", items[0]?.product_id).maybeSingle();
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
          vo.selected_option_ref ? c.optionRef === vo.selected_option_ref : c.name === vo.selected_courier_name);
        if (!selected) return json({ error: "courier_unavailable", message: "Selected courier is no longer available.", vendor_id: vendorId }, 400);
        deliveryFee = Number(selected.fee) || 0;
        deliveryType = "courier";
        courierQuoteId = vo.delivery_quote_id;
        courierName = selected.name;
        courierOptionRef = selected.optionRef;
        courierProvider = selected.provider;
      } else if (deliveryType === "free") {
        deliveryFee = 0;
      } else {
        // No courier was selected and delivery isn't free, so the buyer must be
        // paying a fee agreed with the vendor in chat. Use that fee regardless of
        // the product's delivery_type (mirrors the app's checkout math) — earlier
        // this only ran for negotiate/split, so a courier-typed product with a
        // chat-agreed fee had its delivery silently dropped to ₦0.
        const { data: chats } = await supabase.from("chats").select("id").eq("buyer_id", buyer_id).eq("vendor_id", vendorId);
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
          return json({ error: "no_delivery_fee_agreed", message: "Please agree on a delivery fee with the vendor in chat before checkout.", vendor_id: vendorId }, 400);
        }
        // Reject a stale negotiated fee (old order leftover, or accepted but left
        // unpaid) so checkout never runs on an out-of-date price.
        const feeValidMs =
          (await getNumber("delivery_fee_valid_minutes", "DELIVERY_FEE_VALID_MINUTES", DELIVERY_FEE_VALID_MINUTES_DEFAULT)) * 60_000;
        if (Date.now() - new Date(accepted.created_at).getTime() > feeValidMs) {
          return json({ error: "delivery_fee_expired", message: "The delivery fee you agreed has expired. Please ask the vendor for a fresh delivery fee in chat.", vendor_id: vendorId }, 400);
        }
        deliveryFee = Number(accepted.buyer_fee_amount) || 0;
        vendorContribution = Number(accepted.vendor_contribution) || 0;
        // This fee was agreed in chat = vendor handles delivery. Mark it
        // 'negotiate' (NOT courier) so the vendor is paid the fee and the
        // accepted chat message gets consumed after the order.
        deliveryType = "negotiate";
      }

      enriched.push({
        vendor_id: vendorId, store_id: vo.store_id || "", items, subtotal: itemSubtotal,
        delivery_fee: deliveryFee, delivery_type: deliveryType, vendor_contribution: vendorContribution,
        delivery_quote_id: courierQuoteId, selected_courier_name: courierName,
        selected_option_ref: courierOptionRef, selected_provider: courierProvider,
      });
      total += itemSubtotal + deliveryFee;
    }

    if (enriched.length === 0) return json({ error: "no_valid_orders", message: "No valid items to check out." }, 400);
    if (total <= 0 || total > 50000000) return json({ error: "invalid_amount", message: `Invalid order total (₦${total}).` }, 400);

    // Unique, Flutterwave-safe reference. The webhook creates the orders keyed by it.
    const txRef = `chk${crypto.randomUUID().replace(/-/g, "")}`.slice(0, 42);

    // Store the pending intent BEFORE creating the link, so the webhook always
    // has the verified vendor orders to build from when the charge completes.
    const { error: txErr } = await supabase.from("transactions").insert({
      buyer_id,
      vendor_id: enriched[0].vendor_id,
      store_id: enriched[0].store_id || null,
      amount: total,
      paystack_reference: txRef,
      status: "pending",
      type: "payment",
      metadata: JSON.stringify({ vendor_orders: enriched, total, provider: "flutterwave" }),
    });
    if (txErr) {
      console.error("prepare-checkout intent insert error:", txErr);
      return json({ error: "intent_insert_failed", message: `Could not start checkout: ${txErr.message || txErr.code || "db error"}` }, 500);
    }

    // Return the params for Flutterwave's INLINE checkout (v3.js). Unlike the
    // hosted link, the inline SDK honours `payment_options`, so the buyer's
    // in-app choice (card / banktransfer / ussd / enaira) opens straight to that
    // method. The app renders FlutterwaveCheckout() in a webview. Orders are
    // still created by flutterwave-webhook on charge.completed (tx_ref based).
    if (!flwPublicKey) {
      return json({ error: "no_public_key", message: "Card payments aren't fully configured yet (missing public key)." }, 500);
    }

    return json({
      success: true,
      tx_ref: txRef,
      amount: total,
      public_key: flwPublicKey,
      redirect_url: redirectUrl,
      payment_option: chosenOption, // "" = show all methods
      customer: {
        email: buyer.email,
        name: buyer.name || "Kays Buyer",
        phone: buyer.phone || "",
      },
    });
  } catch (e: any) {
    console.error("prepare-checkout error:", e);
    return json({ error: "checkout_error", message: `Checkout error: ${e?.message || e}` }, 500);
  }
});
