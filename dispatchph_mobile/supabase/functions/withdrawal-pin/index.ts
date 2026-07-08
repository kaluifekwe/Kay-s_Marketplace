import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { hashPin } from "../_shared/pin.ts";

// Manage a vendor/buyer's 4-digit withdrawal PIN.
//   action:"status" -> { has_pin, locked }   (does a PIN exist? is it locked?)
//   action:"set"    -> create the PIN (first time only; body { pin })
// The PIN hash lives in `withdrawal_pins` (service-role only — clients can never
// read the hash). Verifying the PIN happens in wallet-withdraw.

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
    if (!callerId) return json({ error: "Unauthorized" }, 401);

    const { action, pin } = await req.json();
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    if (action === "status") {
      const { data } = await supabase
        .from("withdrawal_pins")
        .select("locked_until")
        .eq("user_id", callerId)
        .maybeSingle();
      const locked = data?.locked_until ? new Date(data.locked_until) > new Date() : false;
      return json({ has_pin: !!data, locked });
    }

    if (action === "set") {
      if (!/^\d{4}$/.test(String(pin ?? ""))) {
        return json({ error: "pin_invalid", message: "PIN must be 4 digits." }, 400);
      }
      // Create only — resetting a forgotten PIN is a separate (future) flow so a
      // stolen session can't silently overwrite it.
      const { data: existing } = await supabase
        .from("withdrawal_pins")
        .select("user_id")
        .eq("user_id", callerId)
        .maybeSingle();
      if (existing) {
        return json({ error: "pin_exists", message: "A withdrawal PIN is already set." }, 409);
      }
      const pin_hash = await hashPin(callerId, String(pin));
      const { error } = await supabase.from("withdrawal_pins").insert({ user_id: callerId, pin_hash });
      if (error) {
        console.error("withdrawal-pin set error:", error);
        return json({ error: "set_failed", message: "Could not set your PIN. Try again." }, 500);
      }
      return json({ success: true });
    }

    return json({ error: "Unknown action" }, 400);
  } catch (e: any) {
    console.error("withdrawal-pin error:", e);
    return json({ error: e.message || "PIN error" }, 500);
  }
});
