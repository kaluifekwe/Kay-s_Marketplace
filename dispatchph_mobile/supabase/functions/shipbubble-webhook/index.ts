import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { shipbubble } from "../_shared/delivery/providers/shipbubble.ts";
import { applyDeliveryStatus, findDelivery, makeClient } from "../_shared/delivery/apply-status.ts";

// Shipbubble delivery status updates → shared applier. Provider-specific bits
// (signature check, payload→event mapping) live here / in the adapter; all the
// deliveries/orders/escrow/push logic is shared in apply-status.ts.

const shipbubbleKey = Deno.env.get("SHIPBUBBLE_API_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const signature = req.headers.get("x-shipbubble-signature") || req.headers.get("shipbubble-signature") || "";
    if (!signature || signature !== shipbubbleKey) return json({ error: "Forbidden" }, 403);

    const payload = await req.json();
    const body = payload.data ?? payload;
    const ev = await shipbubble.parseWebhook(req, body);
    if (!ev) return json({ error: "Missing order_id" }, 400);

    const supabase = makeClient();
    const delivery = await findDelivery(supabase, ev.providerOrderId);
    if (!delivery) return json({ error: "Delivery not found" }, 404);

    await applyDeliveryStatus(supabase, delivery, ev, body.location);
    return json({ success: true });
  } catch (error: any) {
    console.error("shipbubble-webhook error:", error);
    return json({ error: error.message }, 500);
  }
});
