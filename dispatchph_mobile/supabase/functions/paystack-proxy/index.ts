import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const paystackSecretKey = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

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

    if (!getUserIdFromToken(req.headers.get("Authorization"))) {
      return new Response(JSON.stringify({ error: "Authentication required" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { action, ...params } = await req.json();

    if (!action) {
      return new Response(JSON.stringify({ error: "Missing action" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let result: Record<string, unknown>;

    switch (action) {
      case "list-banks": {
        const bankRes = await fetch(
          "https://api.paystack.co/bank?country=nigeria&per_page=200",
          {
            headers: {
              Authorization: `Bearer ${paystackSecretKey}`,
            },
          }
        );
        const bankData = await bankRes.json();
        if (!bankData.status) {
          throw new Error(bankData.message || "Failed to list banks");
        }
        result = { banks: bankData.data };
        break;
      }

      case "resolve-account": {
        const { account_number, bank_code } = params;
        if (!account_number || !bank_code) {
          throw new Error("Missing account_number or bank_code");
        }
        const resolveRes = await fetch(
          `https://api.paystack.co/bank/resolve?account_number=${account_number}&bank_code=${bank_code}`,
          {
            headers: {
              Authorization: `Bearer ${paystackSecretKey}`,
            },
          }
        );
        const resolveData = await resolveRes.json();
        if (!resolveData.status) {
          throw new Error(resolveData.message || "Account verification failed");
        }
        result = resolveData.data;
        break;
      }

      case "create-transfer-recipient": {
        const { name, account_number, bank_code } = params;
        if (!name || !account_number || !bank_code) {
          throw new Error("Missing name, account_number, or bank_code");
        }
        const trRes = await fetch("https://api.paystack.co/transferrecipient", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${paystackSecretKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            type: "nuban",
            name,
            account_number,
            bank_code,
            currency: "NGN",
          }),
        });
        const trData = await trRes.json();
        if (!trData.status) {
          throw new Error(trData.message || "Failed to create transfer recipient");
        }
        result = trData.data;
        break;
      }

      default:
        throw new Error(`Unknown action: ${action}`);
    }

    return new Response(JSON.stringify(result), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
