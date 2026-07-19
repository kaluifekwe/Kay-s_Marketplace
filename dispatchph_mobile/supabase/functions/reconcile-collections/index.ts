import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { flwGet } from "../_shared/flutterwave.ts";

// Scheduled reconciliation of COLLECTIONS — the other direction from
// reconcile-payouts, and the more serious one.
//
// Checkout writes a payment intent (transactions.paystack_reference = chk…,
// status 'pending') and the charge.completed webhook claims it pending →
// success and creates the orders. If that webhook is missed, Flutterwave has
// the customer's money and we created nothing: the buyer paid and got no order,
// with nothing in our system showing a problem.
//
// This job lists successful charges at Flutterwave and checks each one against
// its intent:
//     intent 'success'  → processed, nothing to do
//     intent 'pending'  → MONEY TAKEN, NO ORDER → raise an exception
//     no intent found   → unrecognised reference → raise a low-priority exception
//
// It deliberately DOES NOT create the orders itself. Order creation involves
// delivery quotes, escrow and vendor notification, and replaying it outside the
// webhook's context risks producing a wrong or duplicated order. Taking money
// and silently building an order from a reconstruction is worse than flagging it
// for a human who can either complete or refund it. Detect, don't guess.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

const GRACE_MINUTES = 15;   // don't chase a webhook that may still be in transit
const PAGES = 2;            // bound the work per run
const PAGE_SIZE = 50;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

function isServiceRoleCall(a: string | null) {
  return !!a?.startsWith("Bearer ") && a.replace("Bearer ", "") === supabaseServiceKey;
}
function getUserIdFromToken(a: string | null): string | null {
  if (!a?.startsWith("Bearer ")) return null;
  const token = a.replace("Bearer ", "");
  if (!token || token === supabaseAnonKey) return null;
  try {
    const p = token.split(".");
    if (p.length !== 3) return null;
    const payload = JSON.parse(atob(p[1].replace(/-/g, "+").replace(/_/g, "/")));
    if (payload.exp && payload.exp < Math.floor(Date.now() / 1000)) return null;
    return payload.sub || null;
  } catch {
    return null;
  }
}

const SUCCESS = ["successful", "succeeded", "success", "completed", "complete", "paid"];

async function raiseException(
  supabase: ReturnType<typeof createClient>,
  e: { kind: string; reference: string; amount: number; ourState: string; providerState: string; details: string },
) {
  const { data: existing } = await supabase
    .from("reconciliation_exceptions")
    .select("id")
    .eq("kind", e.kind)
    .eq("target_id", e.reference)
    .eq("status", "open")
    .maybeSingle();
  if (existing) {
    await supabase
      .from("reconciliation_exceptions")
      .update({ last_seen_at: new Date().toISOString(), details: e.details })
      .eq("id", (existing as any).id);
    return;
  }
  await supabase.from("reconciliation_exceptions").insert({
    kind: e.kind,
    reference: e.reference,
    target_type: "charge",
    target_id: e.reference,
    amount: e.amount,
    our_state: e.ourState,
    provider_state: e.providerState,
    details: e.details,
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    if (!isServiceRoleCall(req.headers.get("Authorization"))) {
      const callerId = getUserIdFromToken(req.headers.get("Authorization"));
      if (!callerId) return json({ error: "Unauthorized" }, 401);
      const { data: caller } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
      if (caller?.role !== "admin") return json({ error: "Admin only" }, 403);
    }

    const summary = { scanned: 0, matched: 0, unpaid_orders: 0, unknown_refs: 0, pages: 0, unreachable: false };
    const cutoff = Date.now() - GRACE_MINUTES * 60_000;

    for (let page = 1; page <= PAGES; page++) {
      let res;
      try {
        res = await flwGet(`/charges?page=${page}&size=${PAGE_SIZE}`);
      } catch (e) {
        console.error("reconcile-collections: charges lookup threw:", e);
        summary.unreachable = true;
        break;
      }
      if (!res.ok) {
        console.error(`reconcile-collections: charges lookup failed ${res.status}: ${JSON.stringify(res.data).slice(0, 200)}`);
        summary.unreachable = true;
        break;
      }

      const list = Array.isArray(res.data?.data) ? res.data.data : (Array.isArray(res.data) ? res.data : null);
      if (!list) {
        // Shape not what we expect — stop rather than raise bogus exceptions.
        console.error("reconcile-collections: unexpected charges payload:", JSON.stringify(res.data).slice(0, 300));
        summary.unreachable = true;
        break;
      }
      summary.pages++;
      if (list.length === 0) break;

      for (const c of list) {
        const status = String(c?.status ?? "").toLowerCase();
        if (!SUCCESS.includes(status)) continue;

        const ref = String(c?.tx_ref ?? c?.reference ?? "");
        // Only our checkout intents are reconcilable this way. Anything else
        // (virtual-account funding, other products) is out of scope here.
        if (!ref.startsWith("chk")) continue;

        // Give an in-flight webhook time to land before calling it a problem.
        const created = Date.parse(c?.created_datetime ?? c?.created_at ?? "");
        if (Number.isFinite(created) && created > cutoff) continue;

        summary.scanned++;
        const amount = Number(c?.amount ?? 0) || 0;

        const { data: intent } = await supabase
          .from("transactions")
          .select("id, status, buyer_id, amount")
          .eq("paystack_reference", ref)
          .eq("type", "payment")
          .maybeSingle();

        if (!intent) {
          summary.unknown_refs++;
          await raiseException(supabase, {
            kind: "collection_unknown_reference", reference: ref, amount,
            ourState: "no matching payment intent", providerState: status,
            details: `Flutterwave reports a successful ₦${amount.toLocaleString()} charge for ${ref}, but no payment intent exists in our records.`,
          });
          continue;
        }

        if ((intent as any).status === "pending") {
          // The serious one: money taken, orders never created.
          summary.unpaid_orders++;
          await raiseException(supabase, {
            kind: "collection_not_fulfilled", reference: ref, amount,
            ourState: "payment intent still pending — no orders created", providerState: status,
            details:
              `Flutterwave took ₦${amount.toLocaleString()} for ${ref} but the checkout webhook never completed, ` +
              `so no orders exist. Either complete the order for the buyer or refund them. Do NOT assume the buyer received anything.`,
          });
          continue;
        }

        summary.matched++;
      }

      if (list.length < PAGE_SIZE) break; // last page
    }

    console.log("reconcile-collections:", JSON.stringify(summary));
    return json({ success: true, ...summary });
  } catch (error: any) {
    console.error("reconcile-collections error:", error);
    return json({ error: error.message }, 500);
  }
});
