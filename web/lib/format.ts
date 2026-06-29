export const APP_NAME = "Kay's Marketplace";

export function naira(n: number): string {
  return "₦" + (Number(n) || 0).toLocaleString("en-NG");
}

/** products.images is a JSON string like '["url1","url2"]'. */
export function firstImage(imagesField: unknown): string {
  try {
    if (typeof imagesField === "string" && imagesField.trim().length > 0) {
      const arr = JSON.parse(imagesField);
      if (Array.isArray(arr) && arr.length > 0 && typeof arr[0] === "string") {
        return arr[0];
      }
    }
  } catch {
    /* ignore */
  }
  return "";
}

/** Store/App-store link for the "Get the app" CTA, or null while unpublished. */
export function getAppCtaHref(): string | null {
  return process.env.APP_PLAY_STORE_URL || process.env.APP_STORE_URL || null;
}
