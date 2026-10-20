// Tiny static-IP relay for Flutterwave payouts.
//
// Supabase Edge Functions egress from changing IPs, which Flutterwave's
// transfer endpoint won't allow. This relay runs on Fly.io with ONE dedicated
// IPv4 (whitelisted in Flutterwave). Your wallet-withdraw function fetches the
// Flutterwave OAuth token itself (that step needs no whitelisting) and POSTs the
// transfer here; the relay forwards it to Flutterwave from its fixed IP and
// returns the response verbatim. Flutterwave keys never touch the relay — only a
// short-lived token passes through. Locked with a shared secret.

const http = require("http");
const https = require("https");

const RELAY_SECRET = process.env.RELAY_SECRET || "";
const FLW_BASE = process.env.FLW_BASE || "https://f4bexperience.flutterwave.com";
const PORT = process.env.PORT || 8080;

const server = http.createServer((req, res) => {
  // Health check for Fly.
  if (req.method === "GET" && (req.url === "/" || req.url === "/health")) {
    res.writeHead(200, { "Content-Type": "text/plain" });
    return res.end("ok");
  }

  // Reports THIS relay's outbound IP — the one to whitelist in Flutterwave.
  if (req.method === "GET" && req.url === "/myip") {
    https
      .get("https://api.ipify.org", (r) => {
        let ip = "";
        r.on("data", (d) => (ip += d));
        r.on("end", () => {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ ip: ip.trim() }));
        });
      })
      .on("error", (e) => {
        res.writeHead(502);
        res.end(JSON.stringify({ error: String(e) }));
      });
    return;
  }

  if (req.method !== "POST" || req.url !== "/flw") {
    res.writeHead(404);
    return res.end("not found");
  }
  if (!RELAY_SECRET || req.headers["x-relay-secret"] !== RELAY_SECRET) {
    res.writeHead(401);
    return res.end("unauthorized");
  }

  let raw = "";
  req.on("data", (c) => (raw += c));
  req.on("end", () => {
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      res.writeHead(400);
      return res.end("bad json");
    }
    const { path, token, body, idempotency_key, trace_id, method } = parsed;
    if (!path || !token) {
      res.writeHead(400);
      return res.end("missing path or token");
    }

    // Default POST (payouts); GET is used to RECONCILE a withdrawal by querying
    // the transfer's real status when a webhook was missed. Only these two.
    const httpMethod = String(method || "POST").toUpperCase();
    if (httpMethod !== "POST" && httpMethod !== "GET") {
      res.writeHead(400);
      return res.end("unsupported method");
    }

    const isPost = httpMethod === "POST";
    const payload = isPost ? JSON.stringify(body || {}) : "";
    const url = new URL(FLW_BASE + path);
    const headers = {
      Authorization: "Bearer " + token,
      "X-Idempotency-Key": idempotency_key || "",
      "X-Trace-Id": trace_id || idempotency_key || "",
    };
    if (isPost) {
      headers["Content-Type"] = "application/json";
      headers["Content-Length"] = Buffer.byteLength(payload);
    }
    const options = {
      method: httpMethod,
      hostname: url.hostname,
      path: url.pathname + url.search,
      headers,
    };

    const fReq = https.request(options, (fRes) => {
      let data = "";
      fRes.on("data", (d) => (data += d));
      fRes.on("end", () => {
        res.writeHead(fRes.statusCode || 502, { "Content-Type": "application/json" });
        res.end(data);
      });
    });
    fReq.on("error", (e) => {
      res.writeHead(502, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: String(e) }));
    });
    if (isPost) fReq.write(payload);
    fReq.end();
  });
});

server.listen(PORT, () => console.log(`payout-relay listening on ${PORT}`));
