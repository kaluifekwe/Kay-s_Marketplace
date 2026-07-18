import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { logAdminAction } from "../_shared/audit.ts";
import { invalidateSettingsCache } from "../_shared/settings.ts";

// Update one app_settings row. Admin-gated and run under the service role, so
// the console never gets a write policy on the table. Only keys that already
// exist may be changed — the seed migration defines the allowed surface, so a
// caller can't invent a key that no consumer reads (or squat on a future one).
//
// Values are validated against the row's declared value_type and optional
// min_value/max_value, because these knobs drive money paths (delivery markup,
// minimum withdrawal, price-spike tolerance) and a bad value would otherwise
// propagate straight into live pricing.

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

    const { key, value } = await req.json();
    if (!key || typeof key !== "string") return json({ error: "Missing key" }, 400);
    if (value === undefined || value === null) return json({ error: "Missing value" }, 400);

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: caller } = await supabase.from("users").select("role").eq("id", callerId).maybeSingle();
    if (caller?.role !== "admin") return json({ error: "Admin only" }, 403);

    const { data: row } = await supabase
      .from("app_settings")
      .select("key, value, value_type, min_value, max_value, description")
      .eq("key", key)
      .maybeSingle();
    if (!row) return json({ error: `Unknown setting '${key}'` }, 404);

    // Coerce + validate against the declared type.
    let next: unknown;
    if (row.value_type === "number") {
      const n = Number(value);
      if (!Number.isFinite(n)) return json({ error: "Value must be a number" }, 400);
      if (row.min_value !== null && n < Number(row.min_value)) {
        return json({ error: `Value must be at least ${row.min_value}` }, 400);
      }
      if (row.max_value !== null && n > Number(row.max_value)) {
        return json({ error: `Value must be at most ${row.max_value}` }, 400);
      }
      next = n;
    } else if (row.value_type === "boolean") {
      if (typeof value === "boolean") next = value;
      else if (value === "true" || value === "false") next = value === "true";
      else return json({ error: "Value must be true or false" }, 400);
    } else {
      next = String(value);
    }

    const { data: updated, error } = await supabase
      .from("app_settings")
      .update({ value: next, updated_by: callerId, updated_at: new Date().toISOString() })
      .eq("key", key)
      .select("key, value, value_type, category, description, updated_at")
      .single();
    if (error) {
      console.error("admin-update-setting update error:", error);
      return json({ error: error.message }, 500);
    }

    // Clear this instance's cache. Other warm instances expire within the TTL,
    // so a change is fully live in under a minute.
    invalidateSettingsCache();
    console.log(`app_settings: ${key} -> ${JSON.stringify(next)} by admin ${callerId}`);

    await logAdminAction({
      adminId: callerId, action: "setting.update", targetType: "setting", targetId: key,
      summary: `Changed setting ${key} to ${JSON.stringify(next)}`,
      metadata: { key, new_value: next, previous_value: row.value },
    });
    return json({ success: true, setting: updated });
  } catch (error: any) {
    console.error("admin-update-setting error:", error);
    return json({ error: error.message }, 500);
  }
});
