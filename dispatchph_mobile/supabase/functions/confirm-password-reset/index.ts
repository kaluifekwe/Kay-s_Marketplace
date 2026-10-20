import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Step 2 of the in-app password reset: verify the 6-digit code from
// request-password-reset and set the new password via the admin API (the user
// is logged out, so we update by user id with the service role). Same code
// rules as verify-otp: 10-min expiry, 5 attempts, single-use.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const MAX_ATTEMPTS = 5;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

async function hashCode(code: string, uid: string): Promise<string> {
  const data = new TextEncoder().encode(`${code}:${uid}:${serviceKey}`);
  const buf = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const { email, code, new_password } = await req.json();
    if (!email || typeof email !== "string") return json({ error: "Enter your email." }, 400);
    if (!code || !/^\d{6}$/.test(String(code))) return json({ error: "Enter the 6-digit code from your email." }, 400);
    // Same policy as sign-up: 8+ chars, letters AND numbers.
    const pwd = String(new_password ?? "");
    if (pwd.length < 8 || !/[A-Za-z]/.test(pwd) || !/\d/.test(pwd)) {
      return json({ error: "Password must be at least 8 characters and include both letters and numbers." }, 400);
    }

    const supabase = createClient(supabaseUrl, serviceKey);
    const { data: user } = await supabase
      .from("users").select("id").ilike("email", email.trim()).maybeSingle();
    // Generic message — never reveal whether the email exists.
    if (!user?.id) return json({ error: "Invalid or expired code." }, 400);
    const uid = user.id as string;

    const { data: otp } = await supabase
      .from("email_otps")
      .select("id, code_hash, expires_at, attempts, consumed_at")
      .eq("user_id", uid)
      .is("consumed_at", null)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (!otp) return json({ error: "No active code. Request a new one." }, 400);
    if (new Date(otp.expires_at as string).getTime() < Date.now()) {
      return json({ error: "That code has expired. Request a new one." }, 400);
    }
    if ((otp.attempts as number) >= MAX_ATTEMPTS) {
      return json({ error: "Too many tries. Request a new code." }, 429);
    }

    const candidate = await hashCode(String(code), uid);
    if (candidate !== otp.code_hash) {
      await supabase.from("email_otps").update({ attempts: (otp.attempts as number) + 1 }).eq("id", otp.id);
      const left = MAX_ATTEMPTS - ((otp.attempts as number) + 1);
      return json({ error: left > 0 ? `Incorrect code. ${left} tr${left === 1 ? "y" : "ies"} left.` : "Incorrect code." }, 400);
    }

    // Correct — set the password FIRST, and only consume the code once that
    // succeeded. Consuming first meant a failed reset burned the code, so
    // "please try again" was impossible advice: the retry needed a fresh code,
    // which burned in turn. That loop is how an account became unrecoverable.
    const { error: pwErr } = await supabase.auth.admin.updateUserById(uid, { password: pwd });
    if (pwErr) {
      console.error("confirm-password-reset admin update error:", pwErr);
      // Code is still unconsumed, so the user really can try again.
      return json({ error: "Could not update your password. Please try again." }, 500);
    }
    // Password changed — consume immediately so the code can't be replayed
    // within its remaining validity. Non-fatal: never fail a successful reset.
    const { error: consumeErr } = await supabase
      .from("email_otps").update({ consumed_at: new Date().toISOString() }).eq("id", otp.id);
    if (consumeErr) console.error("confirm-password-reset consume error (non-fatal):", consumeErr);

    return json({ success: true });
  } catch (e: any) {
    console.error("confirm-password-reset error:", e);
    return json({ error: "Reset error. Please try again." }, 500);
  }
});
