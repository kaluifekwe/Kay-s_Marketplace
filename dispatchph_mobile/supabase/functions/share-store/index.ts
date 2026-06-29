import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Public, crawlable storefront page for a single vendor — all their listings in
// a grid, "buy in the app". Shared as the vendor's "store website". Social apps
// read the Open Graph tags for the link preview; humans see the storefront and a
// "Get the app" button. verify_jwt MUST be false (config.toml) so crawlers and
// logged-out visitors can reach it. Products link to the share-product page.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const playStoreUrl = Deno.env.get("APP_PLAY_STORE_URL") ?? "";
const appStoreUrl = Deno.env.get("APP_STORE_URL") ?? "";
const appName = "Kay's Marketplace";

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
  try {
    if (typeof imagesField === "string" && imagesField.trim().length > 0) {
      const arr = JSON.parse(imagesField);
      if (Array.isArray(arr) && arr.length > 0 && typeof arr[0] === "string") {
        return arr[0];
      }
    }
  } catch (_) { /* ignore */ }
  return "";
}

function productHref(req: Request, id: string): string {
  // Sibling function under the same /functions/v1 base.
  const base = new URL(req.url);
  return `${base.origin}/functions/v1/share-product?id=${encodeURIComponent(id)}`;
}

function ctaButton(): string {
  const href = playStoreUrl || appStoreUrl;
  if (href) {
    return `<a class="cta" href="${esc(href)}">Get the ${esc(appName)} app to buy</a>`;
  }
  return `<div class="soon">📱 Buy securely in the ${esc(appName)} app — launching soon on Google Play</div>`;
}

function notFound(): Response {
  return html(
    shell({
      title: "Store not found",
      description: `This store may no longer be available on ${appName}.`,
      image: "",
      bodyHtml: `<p class="empty">Store not found.</p>`,
    }),
    404,
  );
}

function shell(opts: {
  title: string;
  description: string;
  image: string;
  bodyHtml: string;
}): string {
  const { title, description, image, bodyHtml } = opts;
  const t = esc(title);
  const d = esc(description);
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${t} — ${esc(appName)}</title>
<meta name="description" content="${d}" />
<meta property="og:type" content="website" />
<meta property="og:site_name" content="${esc(appName)}" />
<meta property="og:title" content="${t}" />
<meta property="og:description" content="${d}" />
${image ? `<meta property="og:image" content="${esc(image)}" />` : ""}
<meta name="twitter:card" content="summary_large_image" />
<meta name="twitter:title" content="${t}" />
<meta name="twitter:description" content="${d}" />
${image ? `<meta name="twitter:image" content="${esc(image)}" />` : ""}
<style>
  :root { --green:#2E7D32; --ink:#1f2937; --muted:#6b7280; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
         background:#f6f7f9; color:var(--ink); }
  .wrap { max-width:900px; margin:0 auto; padding-bottom:90px; }
  .banner { width:100%; height:180px; object-fit:cover; background:#dfe4e2; display:block; }
  .head { padding:18px 20px; display:flex; gap:14px; align-items:center; background:#fff; }
  .logo { width:64px; height:64px; border-radius:14px; object-fit:cover; background:#eef2f1;
          flex:0 0 auto; display:flex; align-items:center; justify-content:center;
          font-size:26px; color:var(--green); }
  .sname { font-size:22px; font-weight:800; margin:0; display:flex; align-items:center; gap:6px; }
  .verified { color:var(--green); font-size:16px; }
  .sdesc { color:var(--muted); font-size:14px; margin:4px 0 0; }
  .count { color:var(--muted); font-size:13px; padding:14px 20px 4px; }
  .grid { display:grid; grid-template-columns:repeat(2,1fr); gap:12px; padding:8px 16px 16px; }
  @media (min-width:640px){ .grid { grid-template-columns:repeat(3,1fr); } }
  .card { background:#fff; border-radius:14px; overflow:hidden; text-decoration:none;
          color:inherit; box-shadow:0 1px 8px rgba(0,0,0,.06); }
  .pimg { width:100%; aspect-ratio:1/1; object-fit:cover; background:#eee; display:block; }
  .pbody { padding:10px 12px 14px; }
  .pname { font-size:14px; font-weight:600; margin:0 0 4px;
           overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .pprice { font-size:15px; font-weight:800; color:var(--green); margin:0; }
  .empty { text-align:center; color:var(--muted); padding:40px 20px; }
  .bar { position:fixed; left:0; right:0; bottom:0; background:#fff;
         box-shadow:0 -2px 16px rgba(0,0,0,.1); padding:12px 16px; }
  .barwrap { max-width:900px; margin:0 auto; }
  .cta { display:block; text-align:center; background:var(--green); color:#fff;
         text-decoration:none; padding:14px; border-radius:12px; font-weight:700; }
  .soon { text-align:center; background:#eef6ee; color:var(--green);
          padding:12px; border-radius:12px; font-weight:600; font-size:14px; }
</style>
</head>
<body>
  <div class="wrap">
    ${bodyHtml}
  </div>
  <div class="bar"><div class="barwrap">${ctaButton()}</div></div>
</body>
</html>`;
}

function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=300",
    },
  });
}

serve(async (req) => {
  try {
    const url = new URL(req.url);
    const handle = (url.searchParams.get("handle") ?? "").trim().toLowerCase();
    let id = (url.searchParams.get("id") ?? "").trim();
    if (!handle && !id) {
      const parts = url.pathname.split("/").filter(Boolean);
      const last = parts[parts.length - 1] || "";
      if (last && last !== "share-store") id = last;
    }
    if (!handle && !id) return notFound();

    // Look up the store by handle (preferred) or id.
    let q = supabase
      .from("stores")
      .select("id, name, description, logo_path, store_banner_url, is_verified");
    q = handle ? q.eq("handle", handle) : q.eq("id", id);
    const { data: store, error } = await q.maybeSingle();
    if (error || !store) return notFound();

    const { data: products } = await supabase
      .from("products")
      .select("id, name, price, images")
      .eq("store_id", store.id)
      .order("created_at", { ascending: false })
      .limit(60);

    const list = products ?? [];
    const banner = (store.store_banner_url as string) || "";
    const logo = (store.logo_path as string) || "";
    const ogImage = banner || logo || firstImage(list[0]?.images);

    const cards = list
      .map((p: any) => {
        const img = firstImage(p.images);
        return `<a class="card" href="${esc(productHref(req, p.id))}">
          ${img ? `<img class="pimg" src="${esc(img)}" alt="${esc(p.name)}" loading="lazy" />`
                : `<div class="pimg"></div>`}
          <div class="pbody">
            <p class="pname">${esc(p.name)}</p>
            <p class="pprice">${esc(naira(p.price))}</p>
          </div>
        </a>`;
      })
      .join("");

    const body = `
      ${banner ? `<img class="banner" src="${esc(banner)}" alt="${esc(store.name)}" />` : ""}
      <div class="head">
        <div class="logo">${logo ? `<img class="logo" src="${esc(logo)}" alt="" style="box-shadow:none" />` : "🏪"}</div>
        <div>
          <h1 class="sname">${esc(store.name)}${store.is_verified ? ` <span class="verified" title="Verified">✔</span>` : ""}</h1>
          ${store.description ? `<p class="sdesc">${esc(store.description as string)}</p>` : ""}
        </div>
      </div>
      <p class="count">${list.length} ${list.length === 1 ? "item" : "items"}</p>
      ${list.length ? `<div class="grid">${cards}</div>` : `<p class="empty">No products listed yet.</p>`}
    `;

    return html(
      shell({
        title: store.name as string,
        description:
          (store.description as string) ||
          `Shop ${store.name} on ${appName} — secured with escrow protection.`,
        image: ogImage,
        bodyHtml: body,
      }),
    );
  } catch (e: any) {
    console.error("share-store error:", e);
    return notFound();
  }
});
