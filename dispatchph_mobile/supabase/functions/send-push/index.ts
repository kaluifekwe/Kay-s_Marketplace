import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const firebaseServiceAccountEnv = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");

let firebaseServiceAccount: any = null;
try {
  firebaseServiceAccount = JSON.parse(firebaseServiceAccountEnv || "{}");
} catch (e) {
  console.error("Failed to parse FIREBASE_SERVICE_ACCOUNT:", e);
}

async function getAccessToken(): Promise<string | null> {
  if (!firebaseServiceAccount?.client_email || !firebaseServiceAccount?.private_key) {
    console.error("FIREBASE_SERVICE_ACCOUNT not configured or missing fields");
    return null;
  }

  try {
    const now = Math.floor(Date.now() / 1000);
    const expiry = now + 3600;

    const header = { alg: "RS256", typ: "JWT" };
    const payload = {
      iss: firebaseServiceAccount.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: expiry,
    };

    const headerB64 = btoa(JSON.stringify(header)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
    const payloadB64 = btoa(JSON.stringify(payload)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
    const data = `${headerB64}.${payloadB64}`;

    // Parse PEM to DER binary
    const privateKey = firebaseServiceAccount.private_key;
    const pemBody = privateKey
      .replace(/-----BEGIN PRIVATE KEY-----/, "")
      .replace(/-----END PRIVATE KEY-----/, "")
      .replace(/\s+/g, "");

    const binaryDer = Uint8Array.from(atob(pemBody), c => c.charCodeAt(0));

    const cryptoKey = await crypto.subtle.importKey(
      "pkcs8",
      binaryDer,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"]
    );

    const encoder = new TextEncoder();
    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", cryptoKey, encoder.encode(data));
    const signatureB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
      .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

    const jwt = `${headerB64}.${payloadB64}.${signatureB64}`;

    const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
    });

    const tokenData = await tokenResponse.json();
    if (!tokenData.access_token) {
      console.error("Failed to get access token:", tokenData);
      return null;
    }
    return tokenData.access_token;
  } catch (e: any) {
    console.error("getAccessToken error:", e.message);
    return null;
  }
}

async function sendFcmPush(accessToken: string, token: string, title: string, body: string, data: Record<string, string>, channelId: string): Promise<boolean> {
  const message = {
    message: {
      token,
      notification: { title, body },
      data,
      android: {
        priority: "high",
        notification: {
          channelId,
        },
      },
    },
  };

  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${firebaseServiceAccount.project_id}/messages:send`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(message),
    }
  );

  return response.ok;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  try {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({ error: "Method not allowed" }), {
        status: 405,
        headers: { "Content-Type": "application/json" },
      });
    }

    const { user_id, title, body, data } = await req.json();

    if (!user_id || !title || !body) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: user_id, title, body" }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    if (!firebaseServiceAccount) {
      console.error("Firebase service account not configured");
      return new Response(
        JSON.stringify({ success: true, sent: 0, message: "Push not configured" }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: tokens, error } = await supabase
      .from("device_tokens")
      .select("fcm_token")
      .eq("user_id", user_id);

    if (error) {
      console.error("Supabase query error:", error);
      return new Response(JSON.stringify({ error: "Failed to query tokens" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    if (!tokens || tokens.length === 0) {
      console.log(`No tokens found for user ${user_id}`);
      return new Response(
        JSON.stringify({ success: true, sent: 0, message: "No devices registered" }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    const accessToken = await getAccessToken();
    if (!accessToken) {
      return new Response(
        JSON.stringify({ success: true, sent: 0, message: "FCM auth failed" }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    const channelId = data?.type === "chat" ? "chat" : data?.type === "dispute" ? "disputes" : "orders";
    let sentCount = 0;
    let failedCount = 0;

    for (const row of tokens) {
      try {
        const ok = await sendFcmPush(accessToken, row.fcm_token, title, body, data || {}, channelId);
        if (ok) {
          sentCount++;
        } else {
          failedCount++;
        }
      } catch (sendError: any) {
        console.error(`Failed to send to token: ${sendError.message}`);
        failedCount++;
      }
    }

    console.log(`Push sent: ${sentCount} success, ${failedCount} failed for user ${user_id}`);

    return new Response(
      JSON.stringify({ success: true, sent: sentCount, failed: failedCount }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  } catch (error: any) {
    console.error("Edge function error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
