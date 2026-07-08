import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// Diagnostic: reports the outbound (egress) IP this Edge Function uses, so it
// can be whitelisted with providers like Flutterwave. NB: Supabase Edge
// Functions egress from multiple/changing IPs, so this is not guaranteed
// stable — a static-IP proxy is the reliable production fix.
serve(async () => {
  try {
    const res = await fetch("https://api.ipify.org?format=json");
    const data = await res.json();
    return new Response(JSON.stringify(data), {
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
