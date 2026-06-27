import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const paystackSecretKey = Deno.env.get("PAYSTACK_SECRET_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({ error: "Method not allowed" }), {
        status: 405,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const callerId = getUserIdFromToken(req.headers.get("Authorization"));
    const { action, buyer_id, bank_code, account_number } = await req.json();

    if (!buyer_id) {
      return new Response(
        JSON.stringify({ error: "Missing buyer_id" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!callerId || callerId !== buyer_id) {
      return new Response(
        JSON.stringify({ error: "Authenticated user does not match buyer_id" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    if (action === "verify") {
      if (!account_number || !bank_code) {
        return new Response(
          JSON.stringify({ error: "Missing account_number or bank_code" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const resolveResponse = await fetch(
        `https://api.paystack.co/bank/resolve?account_number=${account_number}&bank_code=${bank_code}`,
        {
          headers: {
            Authorization: `Bearer ${paystackSecretKey}`,
            "Content-Type": "application/json",
          },
        }
      );

      const resolveData = await resolveResponse.json();

      if (!resolveData.status) {
        return new Response(
          JSON.stringify({ error: resolveData.message || "Account verification failed" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      return new Response(
        JSON.stringify({
          success: true,
          account_name: resolveData.data.account_name,
          account_number: resolveData.data.account_number,
        }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (action === "save") {
      const { account_name, bank_name } = await req.json();

      if (!account_number || !bank_code || !account_name || !bank_name) {
        return new Response(
          JSON.stringify({ error: "Missing required fields" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Create transfer recipient for potential refunds
      const recipientResponse = await fetch("https://api.paystack.co/transferrecipient", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${paystackSecretKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          type: "nuban",
          name: account_name,
          account_number: account_number,
          bank_code: bank_code,
          currency: "NGN",
        }),
      });

      const recipientData = await recipientResponse.json();
      const recipientCode = recipientData.status ? recipientData.data.recipient_code : null;

      // Upsert buyer bank account
      const { error: saveError } = await supabase.from("buyer_bank_accounts").upsert(
        {
          buyer_id,
          bank_name,
          bank_code,
          account_number,
          account_name,
          paystack_recipient_code: recipientCode,
          is_verified: true,
        },
        { onConflict: "buyer_id" }
      );

      if (saveError) {
        console.error("Save bank error:", saveError);
        return new Response(
          JSON.stringify({ error: "Failed to save bank account" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      return new Response(
        JSON.stringify({ success: true, message: "Bank account saved" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (action === "get") {
      const { data: bank } = await supabase
        .from("buyer_bank_accounts")
        .select("id, bank_name, bank_code, account_number, account_name, is_verified")
        .eq("buyer_id", buyer_id)
        .maybeSingle();

      return new Response(
        JSON.stringify({ success: true, bank }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ error: "Invalid action" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: any) {
    console.error("Edge function error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
