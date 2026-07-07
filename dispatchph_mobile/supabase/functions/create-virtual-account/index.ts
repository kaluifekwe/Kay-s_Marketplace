import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { flwPost } from "../_shared/flutterwave.ts";

// Creates (or returns) a buyer's PERMANENT (static) Flutterwave v4 virtual
// account. In v4 you first create a customer, then create a static virtual
// account under that customer. Flutterwave requires a BVN for permanent NGN
// accounts — we pass it through and DELIBERATELY never store it (only the
// resulting account number/bank + customer id are persisted). The buyer
// transfers into this fixed account; flutterwave-webhook credits their wallet.

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

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Already have an account? Return it (idempotent — never open a second one).
    const { data: wallet } = await supabase
      .from("wallets")
      .select("flw_customer_id, flw_va_number, flw_va_bank")
      .eq("user_id", callerId)
      .maybeSingle();

    if (wallet?.flw_va_number) {
      return json({ account_number: wallet.flw_va_number, bank_name: wallet.flw_va_bank, existing: true });
    }

    const body = await req.json().catch(() => ({}));
    const bvnInput = body?.bvn ? String(body.bvn) : null;

    const { data: user } = await supabase
      .from("users")
      .select("name, email, phone, nin, kyc_status")
      .eq("id", callerId)
      .maybeSingle();
    if (!user?.email) {
      return json({ error: "Buyer email missing. Update your profile before funding." }, 400);
    }

    // Flutterwave accepts NIN *or* BVN for a static NGN virtual account. Prefer
    // the NIN already verified during KYC (no extra prompt); fall back to a BVN
    // the buyer typed only if there's no verified NIN on file.
    const nin = user.kyc_status === "verified" && user.nin ? String(user.nin) : null;
    if (bvnInput && !/^\d{11}$/.test(bvnInput)) {
      return json({ error: "bvn_invalid", message: "BVN must be 11 digits." }, 400);
    }
    if (!nin && !bvnInput) {
      return json({
        error: "identity_required",
        need_bvn: true,
        message: "Verify your identity (NIN) first, or enter your BVN to create a funding account.",
      }, 400);
    }

    const nameParts = String(user.name || "Kays Buyer").trim().split(/\s+/);
    const firstname = nameParts[0] || "Kays";
    const lastname = nameParts.slice(1).join(" ") || "Buyer";

    // 1) Ensure a Flutterwave customer exists for this buyer.
    let customerId: string | null = wallet?.flw_customer_id ?? null;
    if (!customerId) {
      const custBody: Record<string, unknown> = {
        name: { first: firstname, last: lastname },
        email: user.email,
      };
      if (user.phone) {
        // Best-effort E.164-ish split; Flutterwave wants country_code + number.
        const digits = String(user.phone).replace(/\D/g, "");
        const national = digits.startsWith("234") ? digits.slice(3) : digits.replace(/^0/, "");
        custBody.phone = { country_code: "234", number: national };
      }
      const cust = await flwPost("/customers", custBody, `cust_${callerId}`);
      customerId = cust.data?.data?.id ?? cust.data?.id ?? null;
      if (!cust.ok || !customerId) {
        console.error(`Flutterwave create customer error: status=${cust.status} body=${JSON.stringify(cust.data)}`);
        return json({ error: cust.data?.message || "Could not create customer profile" }, 400);
      }
      await supabase.from("wallets").upsert({ user_id: callerId, flw_customer_id: customerId }, { onConflict: "user_id" });
    }

    // 2) Create the static (permanent) virtual account under that customer.
    // Flutterwave requires `reference` to be alphanumeric and 6-42 chars (no
    // hyphens/underscores). Use the UUID stripped of hyphens (32 hex chars) —
    // deterministic per user, so a retry (e.g. after a failed DB save) is
    // idempotent and reuses the same account instead of creating a duplicate.
    const vaRef = callerId.replace(/-/g, "");
    const va = await flwPost(
      "/virtual-accounts",
      {
        reference: vaRef,
        customer_id: customerId,
        amount: 0, // 0 = open-ended static account
        currency: "NGN",
        account_type: "static",
        ...(nin ? { nin } : {}),
        ...(bvnInput ? { bvn: bvnInput } : {}),
        narration: `${firstname} ${lastname}`.trim(),
      },
      vaRef
    );

    const vaData = va.data?.data ?? va.data;
    const accountNumber = vaData?.account_number;
    const bankName = vaData?.account_bank_name ?? vaData?.bank_name ?? vaData?.account_bank;
    if (!va.ok || !accountNumber) {
      console.error(`Flutterwave create VA error: status=${va.status} body=${JSON.stringify(va.data)}`);
      return json({ error: va.data?.message || "Could not create funding account" }, 400);
    }

    // Persist ONLY account details + customer id — never the BVN.
    const { error: upErr } = await supabase.from("wallets").upsert(
      {
        user_id: callerId,
        flw_customer_id: customerId,
        flw_va_number: accountNumber,
        flw_va_bank: bankName,
        flw_va_reference: vaRef,
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
