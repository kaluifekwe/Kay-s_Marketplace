import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Step 1 of the in-app password reset: email a 6-digit code to a user who
// forgot their password. Works for logged-OUT users (keyed by email, not
// auth.uid). The code is stored HASHED in email_otps (same table as signup
// verification) with a 10-min expiry, 1/min rate limit. Confirmed by
// confirm-password-reset. Always returns success for unknown emails so the
// endpoint can't be used to discover which emails are registered.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";
const fromEmail = Deno.env.get("OTP_FROM_EMAIL") ?? "Kay's Market <noreply@send.kaysmarket.com.ng>";

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

function sixDigitCode(): string {
  const a = new Uint32Array(1);
  crypto.getRandomValues(a);
  return String(100000 + (a[0] % 900000));
}

function resetEmailHtml(code: string): string {
  const logo = "https://kaysmarket-legal.web.app/logo.png";
  return `<!doctype html><html><body style="margin:0;background:#f6f8fa;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:32px 16px;">
    <table width="100%" style="max-width:480px;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 6px 24px rgba(20,40,30,.06);">
      <tr><td align="center" style="padding:30px 28px 4px;">
        <img src="${logo}" alt="Kay's Market" width="150" style="display:block;width:150px;max-width:60%;height:auto;margin:0 auto;" />
      </td></tr>
      <tr><td style="padding:6px 30px 10px;text-align:center;">
        <h1 style="margin:0 0 6px;font-size:21px;color:#1f2430;">Reset your password</h1>
        <p style="margin:0 0 18px;font-size:15px;color:#5b6472;line-height:1.6;">Enter this code in the Kay's Market app to set a new password. It expires in 10 minutes.</p>
        <div style="background:#f0f7f2;border:1px solid #d8ebdf;border-radius:12px;padding:18px;margin:0 0 18px;">
          <span style="font-size:36px;font-weight:700;letter-spacing:8px;color:#14672c;">${code}</span>
        </div>
        <p style="margin:0;font-size:13px;color:#8a94a3;line-height:1.6;">If you didn't request a password reset, you can safely ignore this email — your password stays unchanged.</p>
      </td></tr>
      <tr><td style="padding:20px 28px 28px;color:#8a94a3;font-size:12px;text-align:center;border-top:1px solid #eef1f4;">— The Kay's Market Team &middot; <a href="https://kaysmarket.com.ng" style="color:#1b8a3a;text-decoration:none;">kaysmarket.com.ng</a></td></tr>
    </table>
  </td></tr></table></body></html>`;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const { email } = await req.json();
    if (!email || typeof email !== "string") return json({ error: "Enter your email." }, 400);

    const supabase = createClient(supabaseUrl, serviceKey);
    const { data: user } = await supabase
      .from("users")
      .select("id, email")
      .ilike("email", email.trim())
      .maybeSingle();

    // Unknown email — pretend success so the endpoint can't enumerate accounts.
    if (!user?.id) return json({ success: true });
    const uid = user.id as string;

    // Rate limit: one code per minute.
    const { data: last } = await supabase
      .from("email_otps").select("created_at").eq("user_id", uid)
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (last && Date.now() - new Date(last.created_at as string).getTime() < 60_000) {
      return json({ error: "Please wait a minute before requesting another code." }, 429);
    }

    const code = sixDigitCode();
    const codeHash = await hashCode(code, uid);
    const expiresAt = new Date(Date.now() + 10 * 60_000).toISOString();
    await supabase.from("email_otps").delete().eq("user_id", uid).is("consumed_at", null);
    const { error: insErr } = await supabase.from("email_otps").insert({
      user_id: uid, email: user.email, code_hash: codeHash, expires_at: expiresAt,
    });
    if (insErr) {
      console.error("request-password-reset insert error:", insErr);
      return json({ error: "Could not start reset. Please try again." }, 500);
    }

    if (!resendKey) return json({ error: "Email sending isn't configured yet." }, 500);
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: fromEmail,
        to: [user.email],
        subject: `${code} is your Kay's Market password reset code`,
        html: resetEmailHtml(code),
      }),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      console.error("request-password-reset resend error:", res.status, body);
      let reason = `HTTP ${res.status}`;
      try { const j = JSON.parse(body); if (j?.message) reason = j.message; } catch { /* keep status */ }
      return json({ error: "resend_failed", message: `Couldn't send the code: ${reason}` }, 502);
    }

    return json({ success: true });
  } catch (e: any) {
    console.error("request-password-reset error:", e);
    return json({ error: "Reset error. Please try again." }, 500);
  }
});
