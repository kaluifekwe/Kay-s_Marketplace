import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Public, crawlable product page for sharing to WhatsApp / Facebook / X / etc.
// Social apps fetch this URL server-side and read the Open Graph (og:) tags to
// build the rich link preview (image + title). A human who taps it sees the
// product and a "Get the app" button. verify_jwt MUST be false (see config.toml)
// so unauthenticated crawlers can reach it.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Set these once the app is published so the CTA links to the real listings.
const playStoreUrl = Deno.env.get("APP_PLAY_STORE_URL") ?? "";
const appStoreUrl = Deno.env.get("APP_STORE_URL") ?? "";
const appName = "Kay's Market";

const supabase = createClient(supabaseUrl, supabaseServiceKey);

function esc(s: string): string {
  return (s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function naira(n: number): string {
  return "₦" + (Number(n) || 0).toLocaleString("en-NG");
}

function firstImage(imagesField: unknown): string {
  // products.images is a JSON string like '["url1","url2"]'.
  try {
    if (typeof imagesField === "string" && imagesField.trim().length > 0) {
      const arr = JSON.parse(imagesField);
      if (Array.isArray(arr) && arr.length > 0 && typeof arr[0] === "string") {
        return arr[0];
      }
    } else if (Array.isArray(imagesField) && imagesField.length > 0) {
      return String(imagesField[0]);
    }
  } catch (_) {
    // fall through
  }
  return "";
}

function ctaButton(): string {
  // Prefer Play Store; fall back to App Store; else a "coming soon" note.
  const href = playStoreUrl || appStoreUrl;
  if (href) {
    return `<a class="cta" href="${esc(href)}">Get the ${esc(appName)} app</a>`;
  }
  return `<div class="soon">📱 ${esc(appName)} is launching soon on Google Play</div>`;
}

function page(opts: {
  title: string;
  description: string;
  image: string;
  priceText: string;
  storeName: string;
}): string {
  const { title, description, image, priceText, storeName } = opts;
  const ogTitle = esc(title);
  const ogDesc = esc(description || `${priceText} on ${appName}`);
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${ogTitle} — ${esc(appName)}</title>
<meta name="description" content="${ogDesc}" />
<meta property="og:type" content="product" />
<meta property="og:site_name" content="${esc(appName)}" />
<meta property="og:title" content="${ogTitle}" />
<meta property="og:description" content="${ogDesc}" />
${image ? `<meta property="og:image" content="${esc(image)}" />` : ""}
<meta name="twitter:card" content="summary_large_image" />
<meta name="twitter:title" content="${ogTitle}" />
<meta name="twitter:description" content="${ogDesc}" />
${image ? `<meta name="twitter:image" content="${esc(image)}" />` : ""}
<style>
  :root { --green:#2E7D32; --ink:#1f2937; --muted:#6b7280; }
  * { box-sizing: border-box; }
  body { margin:0; font-family: system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
         background:#f6f7f9; color:var(--ink); }
  .wrap { max-width:520px; margin:0 auto; padding:20px; }
  .card { background:#fff; border-radius:16px; overflow:hidden;
          box-shadow:0 2px 16px rgba(0,0,0,.08); }
  .img { width:100%; aspect-ratio:1/1; object-fit:cover; background:#eee; display:block; }
  .body { padding:18px; }
  .name { font-size:20px; font-weight:700; margin:0 0 6px; }
  .price { font-size:22px; font-weight:800; color:var(--green); margin:0 0 4px; }
  .store { font-size:13px; color:var(--muted); margin:0 0 14px; }
  .desc { font-size:14px; color:#374151; line-height:1.5; margin:0 0 18px;
          white-space:pre-wrap; }
  .cta { display:block; text-align:center; background:var(--green); color:#fff;
         text-decoration:none; padding:14px; border-radius:12px; font-weight:700; }
  .soon { text-align:center; background:#eef6ee; color:var(--green);
          padding:14px; border-radius:12px; font-weight:600; }
  .brand { text-align:center; color:var(--muted); font-size:12px; margin-top:16px; }
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      ${image ? `<img class="img" src="${esc(image)}" alt="${ogTitle}" />` : ""}
      <div class="body">
        <p class="price">${esc(priceText)}</p>
        <h1 class="name">${ogTitle}</h1>
        ${storeName ? `<p class="store">Sold by ${esc(storeName)}</p>` : ""}
        ${description ? `<p class="desc">${esc(description)}</p>` : ""}
        ${ctaButton()}
      </div>
    </div>
    <p class="brand">🔒 ${esc(appName)} — secured with escrow protection</p>
  </div>
</body>
</html>`;
}

function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      // Let crawlers/CDN cache the preview briefly.
      "Cache-Control": "public, max-age=300",
    },
  });
}

serve(async (req) => {
  try {
    const url = new URL(req.url);
    // Accept ?id=<uuid> or a trailing path segment (.../share-product/<id>).
    let id = url.searchParams.get("id") ?? "";
    if (!id) {
      const parts = url.pathname.split("/").filter(Boolean);
      id = parts[parts.length - 1] || "";
      if (id === "share-product") id = "";
    }

    if (!id) {
      return html(
        page({
          title: appName,
          description: "Shop trusted vendors with escrow protection.",
          image: "",
          priceText: "",
          storeName: "",
        }),
        400,
      );
    }

    const { data: product, error } = await supabase
      .from("products")
      .select("id, name, description, price, images, store_id")
      .eq("id", id)
      .maybeSingle();

    if (error || !product) {
      return html(
        page({
          title: "Product not found",
          description: `This item may no longer be available on ${appName}.`,
          image: "",
          priceText: "",
          storeName: "",
        }),
        404,
      );
    }

    // Store name is best-effort — a failure here shouldn't break the page.
    let storeName = "";
    try {
      const { data: store } = await supabase
        .from("stores")
        .select("name")
        .eq("id", product.store_id)
        .maybeSingle();
      storeName = (store?.name as string) ?? "";
    } catch (_) {
      // ignore
    }

    return html(
      page({
        title: product.name as string,
        description: (product.description as string) ?? "",
        image: firstImage(product.images),
        priceText: naira(product.price as number),
        storeName,
      }),
    );
  } catch (e: any) {
    console.error("share-product error:", e);
    return html(
      page({
        title: appName,
        description: "Shop trusted vendors with escrow protection.",
        image: "",
        priceText: "",
        storeName: "",
      }),
      500,
    );
  }
});
