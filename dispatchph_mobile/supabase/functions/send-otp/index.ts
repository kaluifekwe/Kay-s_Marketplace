import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Email verification: send a 6-digit code to the caller (the just-signed-up
// user) via Resend. The code is stored HASHED (SHA-256 with the service key as
// pepper) with a 10-minute expiry; any previous unconsumed code is cleared
// first. Rate-limited to one send per minute. Verified by verify-otp.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";
// From address must be on a domain verified in Resend (e.g. send.kaysmarket.com.ng).
const fromEmail = Deno.env.get("OTP_FROM_EMAIL") ?? "Kay's Market <noreply@send.kaysmarket.com.ng>";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

function callerId(authHeader: string | null): string | null {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return null;
  const token = authHeader.replace("Bearer ", "");
  if (!token || token === anonKey) return null;
  try {
    const p = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    if (p.exp && p.exp < Math.floor(Date.now() / 1000)) return null;
    return p.sub || null;
  } catch {
    return null;
  }
}

async function hashCode(code: string, uid: string): Promise<string> {
  const data = new TextEncoder().encode(`${code}:${uid}:${serviceKey}`);
  const buf = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sixDigitCode(): string {
  const a = new Uint32Array(1);
  crypto.getRandomValues(a);
  return String(100000 + (a[0] % 900000));
}

function otpEmailHtml(code: string): string {
  const logo = "https://kaysmarket-legal.web.app/logo.png";
  return `<!doctype html><html><body style="margin:0;background:#f6f8fa;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:32px 16px;">
    <table width="100%" style="max-width:480px;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 6px 24px rgba(20,40,30,.06);">
      <tr><td align="center" style="padding:30px 28px 4px;">
        <img src="${logo}" alt="Kay's Market" width="150" style="display:block;width:150px;max-width:60%;height:auto;margin:0 auto;" />
      </td></tr>
      <tr><td style="padding:6px 30px 10px;text-align:center;">
        <h1 style="margin:0 0 6px;font-size:21px;color:#1f2430;">Confirm your email</h1>
        <p style="margin:0 0 18px;font-size:15px;color:#5b6472;line-height:1.6;">Enter this code in the Kay's Market app to verify your account. It expires in 10 minutes.</p>
        <div style="background:#f0f7f2;border:1px solid #d8ebdf;border-radius:12px;padding:18px;margin:0 0 18px;">
          <span style="font-size:36px;font-weight:700;letter-spacing:8px;color:#14672c;">${code}</span>
        </div>
        <p style="margin:0;font-size:13px;color:#8a94a3;line-height:1.6;">If you didn't create a Kay's Market account, you can safely ignore this email.</p>
      </td></tr>
      <tr><td style="padding:20px 28px 28px;color:#8a94a3;font-size:12px;text-align:center;border-top:1px solid #eef1f4;">— The Kay's Market Team &middot; <a href="https://kaysmarket.com.ng" style="color:#1b8a3a;text-decoration:none;">kaysmarket.com.ng</a></td></tr>
    </table>
  </td></tr></table></body></html>`;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const uid = callerId(req.headers.get("Authorization"));
    if (!uid) return json({ error: "Authentication required" }, 401);

    const supabase = createClient(supabaseUrl, serviceKey);

    const { data: me } = await supabase
      .from("users")
      .select("email, email_verified")
      .eq("id", uid)
      .maybeSingle();
    if (!me?.email) return json({ error: "Account not found" }, 404);
    if (me.email_verified === true) return json({ success: true, alreadyVerified: true });

    // Rate limit: one code per minute.
    const { data: last } = await supabase
      .from("email_otps")
      .select("created_at")
      .eq("user_id", uid)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (last && Date.now() - new Date(last.created_at as string).getTime() < 60_000) {
      return json({ error: "Please wait a minute before requesting another code." }, 429);
    }

    const code = sixDigitCode();
    const codeHash = await hashCode(code, uid);
    const expiresAt = new Date(Date.now() + 10 * 60_000).toISOString();

    // Clear any previous unconsumed code, then store the new one.
    await supabase.from("email_otps").delete().eq("user_id", uid).is("consumed_at", null);
    const { error: insErr } = await supabase.from("email_otps").insert({
      user_id: uid,
      email: me.email,
      code_hash: codeHash,
      expires_at: expiresAt,
    });
    if (insErr) {
      console.error("send-otp insert error:", insErr);
      return json({ error: "Could not start verification. Please try again." }, 500);
    }

    if (!resendKey) {
      // Not configured yet — log the code so the flow is testable pre-Resend.
      // NEVER leave this in production without a real key.
      console.log(`send-otp: RESEND_API_KEY missing. DEV code for ${uid}: ${code}`);
      return json({ error: "Email sending isn't configured yet." }, 500);
    }

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: fromEmail,
        to: [me.email],
        subject: `${code} is your Kay's Market verification code`,
        html: otpEmailHtml(code),
      }),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      console.error("send-otp resend error:", res.status, body);
      // Surface Resend's own reason (e.g. "domain is not verified") so we can
      // diagnose instead of a generic message.
      let reason = `HTTP ${res.status}`;
      try { const j = JSON.parse(body); if (j?.message) reason = j.message; } catch { /* keep status */ }
      return json({ error: "resend_failed", message: `Couldn't send the code: ${reason}` }, 502);
    }

    return json({ success: true });
  } catch (e: any) {
    console.error("send-otp error:", e);
    return json({ error: "Verification error. Please try again." }, 500);
  }
});
