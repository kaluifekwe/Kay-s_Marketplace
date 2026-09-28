import { supabaseHost } from "./supabase";

export const APP_NAME = "Kay's Market";

export function naira(n: number): string {
  return "₦" + (Number(n) || 0).toLocaleString("en-NG");
}

/**
 * Only accept images served from OUR Supabase Storage (https, our host, the
 * public-object path). Anything else a vendor might have stored (other hosts,
 * javascript:, data:, tracking pixels) is dropped.
 */
export function safeImageUrl(u: unknown): string {
  if (typeof u !== "string" || u.length > 600) return "";
  try {
    const url = new URL(u);
    if (url.protocol !== "https:") return "";
    if (url.host !== supabaseHost()) return "";
    if (!url.pathname.startsWith("/storage/v1/")) return "";
    return url.toString();
  } catch {
    return "";
  }
}

/** products.images is a JSON string like '["url1","url2"]'. */
export function imageList(imagesField: unknown): string[] {
  try {
    if (typeof imagesField === "string" && imagesField.trim().length > 0) {
      const arr = JSON.parse(imagesField);
      if (Array.isArray(arr)) {
        return arr.map(safeImageUrl).filter(Boolean).slice(0, 4);
      }
    }
  } catch {
    /* ignore */
  }
  return [];
}

export function firstImage(imagesField: unknown): string {
  return imageList(imagesField)[0] ?? "";
}

/**
 * Play Store link for the "Get the app" CTA. It is a fixed value from the
 * environment, never built from user input (no open redirect). Null while the
 * app is unpublished.
 */
export function getAppCtaHref(): string | null {
  const v = process.env.APP_PLAY_STORE_URL || process.env.APP_STORE_URL || "";
  try {
    const u = new URL(v);
    return u.protocol === "https:" ? u.toString() : null;
  } catch {
    return null;
  }
}

/** Absolute site origin for canonical URLs, sitemap and structured data. */
export function siteUrl(): string {
  return (process.env.SITE_URL || "https://kaysmarket.com.ng").replace(/\/+$/, "");
}

/** Serialize JSON-LD safely: `<` is escaped so it can never close the tag. */
export function jsonLd(data: unknown): string {
  return JSON.stringify(data).replace(/</g, "\\u003c");
}
