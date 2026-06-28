import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { terminal } from "../_shared/delivery/providers/terminal.ts";
import { applyDeliveryStatus, findDelivery, makeClient } from "../_shared/delivery/apply-status.ts";

// Terminal Africa (TShip) delivery status updates → shared applier.
// Terminal posts { event, data } (e.g. shipment.in-transit / shipment.delivered).
// Optional shared-secret check via TERMINAL_WEBHOOK_SECRET — configure the same
// value in the Terminal dashboard's webhook settings for production.

const webhookSecret = Deno.env.get("TERMINAL_WEBHOOK_SECRET") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-terminal-signature",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    // If a secret is configured, require it; otherwise accept (sandbox).
    if (webhookSecret) {
      const sig = req.headers.get("x-terminal-signature") || req.headers.get("terminal-signature") || "";
      if (sig !== webhookSecret) return json({ error: "Forbidden" }, 403);
    }

    const payload = await req.json();
    const ev = await terminal.parseWebhook(req, payload);
    if (!ev) return json({ ok: true, ignored: true }); // unknown event — ack so Terminal stops retrying

    const supabase = makeClient();
    const delivery = await findDelivery(supabase, ev.providerOrderId);
    if (!delivery) return json({ error: "Delivery not found" }, 404);

    await applyDeliveryStatus(supabase, delivery, ev);
    return json({ success: true });
  } catch (error: any) {
    console.error("terminal-webhook error:", error);
    return json({ error: error.message }, 500);
  }
});
