import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Creates (or returns) a buyer's PERMANENT Flutterwave virtual account. The
// buyer transfers money to this fixed account number; the flutterwave-webhook
// credits their wallet on receipt. Flutterwave requires a BVN to open a
// permanent NGN account — we pass it through to Flutterwave and deliberately
// DO NOT store it (only the resulting account number/bank are persisted).

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const flwSecretKey = Deno.env.get("FLUTTERWAVE_SECRET_KEY")!;

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

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Already have one? Return it (idempotent — never create a second account).
    const { data: wallet } = await supabase
      .from("wallets")
      .select("flw_va_number, flw_va_bank")
      .eq("user_id", callerId)
      .maybeSingle();

    if (wallet?.flw_va_number) {
      return json({
        account_number: wallet.flw_va_number,
        bank_name: wallet.flw_va_bank,
        existing: true,
      });
    }

    const { bvn } = await req.json().catch(() => ({}));
    if (!bvn || !/^\d{11}$/.test(String(bvn))) {
      return json({ error: "bvn_required", message: "A valid 11-digit BVN is required to create your funding account." }, 400);
    }

    // Buyer identity for the account (name/email/phone).
    const { data: user } = await supabase
      .from("users")
      .select("name, email, phone")
      .eq("id", callerId)
      .maybeSingle();
    if (!user?.email) {
      return json({ error: "Buyer email missing. Update your profile before funding." }, 400);
    }

    const nameParts = String(user.name || "Kays Buyer").trim().split(/\s+/);
    const firstname = nameParts[0] || "Kays";
    const lastname = nameParts.slice(1).join(" ") || "Buyer";
    const txRef = `wallet_${callerId}`;

    // Flutterwave v3: create a permanent virtual account.
    const flwRes = await fetch("https://api.flutterwave.com/v3/virtual-account-numbers", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${flwSecretKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        email: user.email,
        is_permanent: true,
        bvn: String(bvn),
        tx_ref: txRef,
        phonenumber: user.phone || undefined,
        firstname,
        lastname,
        narration: `${firstname} ${lastname}`.trim(),
      }),
    });

    const flwData = await flwRes.json();
    if (flwData.status !== "success" || !flwData.data?.account_number) {
      console.error("Flutterwave VA create error:", flwData);
      return json({ error: flwData.message || "Could not create funding account" }, 400);
    }

    const accountNumber = flwData.data.account_number as string;
    const bankName = flwData.data.bank_name as string;
    const flwRef = (flwData.data.flw_ref || flwData.data.order_ref || txRef) as string;

    // Persist ONLY the account details — never the BVN. Auto-creates the wallet
    // row via upsert (balance defaults to 0).
    const { error: upErr } = await supabase.from("wallets").upsert(
      {
        user_id: callerId,
        flw_va_number: accountNumber,
        flw_va_bank: bankName,
        flw_va_reference: flwRef,
      },
      { onConflict: "user_id" }
    );
    if (upErr) {
      console.error("wallet upsert error:", upErr);
      return json({ error: "Account created but could not be saved. Contact support." }, 500);
    }

    return json({ account_number: accountNumber, bank_name: bankName, existing: false });
  } catch (error: any) {
    console.error("create-virtual-account error:", error);
    return json({ error: error.message }, 500);
  }
});
