import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Verify the 6-digit email code the caller received from send-otp. On a correct,
// unexpired, non-exhausted code we mark users.email_verified = true and consume
// the code. Wrong codes increment an attempt counter (max 5) so codes can't be
// brute-forced.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const MAX_ATTEMPTS = 5;

// Founder welcome email (scheduled ~10 min after verification, role-aware).
const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";
const welcomeFrom = Deno.env.get("WELCOME_FROM_EMAIL") ?? "Kalu Ifekwe (Kay's Market) <kalu@send.kaysmarket.com.ng>";
const WELCOME_DELAY_MIN = Number(Deno.env.get("WELCOME_DELAY_MINUTES") ?? "10");

function welcomeHtml(isVendor: boolean, firstName: string): string {
  const logo = "https://kaysmarket-legal.web.app/logo.png";
  const intro = isVendor
    ? `Thank you for joining <b>Kay's Market</b> as a <b>vendor</b> — I'm genuinely excited to help you sell. We connect you to buyers in your state and handle payments and escrow, so you get paid reliably.`
    : `Thank you for joining <b>Kay's Market</b> as a <b>buyer</b>. You can now shop from trusted vendors in your state, with your money held safely in escrow until you confirm delivery — so you buy with total confidence.`;
  const steps = isVendor
    ? [
        "Add your first products with clear photos and prices",
        "Set up your bank account so you can withdraw your earnings",
        "Reply to buyer chats and delivery requests quickly to win more sales",
      ]
    : [
        "Browse products from vendors near you",
        "Chat with a vendor before you buy",
        "Pay by card, transfer, USSD or wallet — every order is escrow-protected",
      ];
  const stepsHtml = steps
    .map((s) => `<tr><td style="padding:4px 0;color:#3c4658;font-size:15px;line-height:1.6;">✅ ${s}</td></tr>`)
    .join("");
  const closing = isVendor ? "Let's grow your business together," : "Welcome aboard,";
  return `<!doctype html><html><body style="margin:0;background:#f6f8fa;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:32px 16px;">
    <table width="100%" style="max-width:520px;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 6px 24px rgba(20,40,30,.06);">
      <tr><td align="center" style="padding:28px 28px 6px;">
        <img src="${logo}" alt="Kay's Market" width="140" style="display:block;width:140px;max-width:55%;height:auto;margin:0 auto;" />
      </td></tr>
      <tr><td style="padding:8px 32px 8px;">
        <h1 style="margin:0 0 12px;font-size:22px;color:#1f2430;">Hi ${firstName}, welcome! 🎉</h1>
        <p style="margin:0 0 14px;font-size:15px;color:#3c4658;line-height:1.7;">I'm <b>Kalu</b>, the founder of Kay's Market, and I wanted to personally say hello. ${intro}</p>
        <p style="margin:0 0 8px;font-size:15px;color:#1f2430;font-weight:600;">Here's what to do next:</p>
        <table cellpadding="0" cellspacing="0" style="margin:0 0 16px;">${stepsHtml}</table>
        <p style="margin:0 0 18px;font-size:15px;color:#3c4658;line-height:1.7;">If you ever need anything, just reply to this email — it comes straight to me.</p>
        <p style="margin:0;font-size:15px;color:#3c4658;line-height:1.6;">${closing}<br><b style="color:#14672c;">Kalu Ifekwe</b><br><span style="color:#8a94a3;font-size:13px;">Founder, Kay's Market</span></p>
      </td></tr>
      <tr><td style="padding:20px 28px 28px;color:#8a94a3;font-size:12px;text-align:center;border-top:1px solid #eef1f4;">Kay's Market &middot; <a href="https://kaysmarket.com.ng" style="color:#1b8a3a;text-decoration:none;">kaysmarket.com.ng</a></td></tr>
    </table>
  </td></tr></table></body></html>`;
}

// Schedule the founder welcome email. Non-fatal — never blocks verification.
async function scheduleWelcomeEmail(supabase: any, uid: string): Promise<void> {
  if (!resendKey) return;
  const { data: u } = await supabase.from("users").select("email, name, role").eq("id", uid).maybeSingle();
  if (!u?.email) return;
  const isVendor = String(u.role ?? "").toLowerCase() === "vendor";
  const firstName = String(u.name ?? "there").trim().split(/\s+/)[0] || "there";
  const subject = isVendor
    ? `Welcome to Kay's Market, ${firstName} — let's get your store selling`
    : `Welcome to Kay's Market, ${firstName}!`;
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: welcomeFrom,
      to: [u.email],
      // So replies reach a real inbox (the send. subdomain is send-only).
      reply_to: Deno.env.get("WELCOME_REPLY_TO") ?? "support@kaysmarket.com.ng",
      subject,
      scheduled_at: new Date(Date.now() + WELCOME_DELAY_MIN * 60_000).toISOString(),
      html: welcomeHtml(isVendor, firstName),
    }),
  });
  if (!res.ok) {
    console.error("welcome email send failed:", res.status, (await res.text().catch(() => "")).slice(0, 200));
  }
}

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

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const uid = callerId(req.headers.get("Authorization"));
    if (!uid) return json({ error: "Authentication required" }, 401);

    const { code } = await req.json();
    if (!code || !/^\d{6}$/.test(String(code))) {
      return json({ error: "Enter the 6-digit code from your email." }, 400);
    }

    const supabase = createClient(supabaseUrl, serviceKey);

    // Already verified? idempotent success.
    const { data: me } = await supabase.from("users").select("email_verified").eq("id", uid).maybeSingle();
    if (me?.email_verified === true) return json({ success: true, verified: true });

    const { data: otp } = await supabase
      .from("email_otps")
      .select("id, code_hash, expires_at, attempts, consumed_at")
      .eq("user_id", uid)
      .is("consumed_at", null)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!otp) return json({ error: "No active code. Tap Resend to get a new one." }, 400);
    if (new Date(otp.expires_at as string).getTime() < Date.now()) {
      return json({ error: "That code has expired. Tap Resend to get a new one." }, 400);
    }
    if ((otp.attempts as number) >= MAX_ATTEMPTS) {
      return json({ error: "Too many tries. Tap Resend to get a new code." }, 429);
    }

    const candidate = await hashCode(String(code), uid);
    if (candidate !== otp.code_hash) {
      await supabase.from("email_otps").update({ attempts: (otp.attempts as number) + 1 }).eq("id", otp.id);
      const left = MAX_ATTEMPTS - ((otp.attempts as number) + 1);
      return json({ error: left > 0 ? `Incorrect code. ${left} tr${left === 1 ? "y" : "ies"} left.` : "Incorrect code." }, 400);
    }

    // Correct — mark the account verified FIRST, and only consume the code once
    // that succeeded. Consuming first meant a failed update burned the code, so
    // "please try again" was impossible advice: the retry needed a fresh code,
    // which burned in turn. Order matters more than it looks.
    const { error: upErr } = await supabase.from("users").update({ email_verified: true }).eq("id", uid);
    if (upErr) {
      console.error("verify-otp update error:", upErr);
      // Code is still unconsumed, so the user really can try again.
      return json({ error: "Verification error. Please try again." }, 500);
    }
    // Verified. If this consume fails the code stays live until it expires, but
    // the early "already verified" return above makes reuse a no-op — so it's
    // non-fatal and must never fail the request.
    const { error: consumeErr } = await supabase
      .from("email_otps").update({ consumed_at: new Date().toISOString() }).eq("id", otp.id);
    if (consumeErr) console.error("verify-otp consume error (non-fatal):", consumeErr);

    // First-time verification only (idempotent success above returns early), so
    // the welcome email schedules exactly once. Non-fatal.
    try {
      await scheduleWelcomeEmail(supabase, uid);
    } catch (e) {
      console.error("welcome email schedule error:", e);
    }

    return json({ success: true, verified: true });
  } catch (e: any) {
    console.error("verify-otp error:", e);
    return json({ error: "Verification error. Please try again." }, 500);
  }
});
