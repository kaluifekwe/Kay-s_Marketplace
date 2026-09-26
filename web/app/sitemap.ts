import type { MetadataRoute } from "next";
import { sitemapEntries } from "@/lib/data";
import { siteUrl } from "@/lib/format";
import { STATES, slugify } from "@/lib/validate";

export const revalidate = 3600;

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const base = siteUrl();
  const { products, stores } = await sitemapEntries().catch(() => ({ products: [], stores: [] }));
  return [
    { url: `${base}/`, changeFrequency: "daily", priority: 1 },
    { url: `${base}/stores`, changeFrequency: "daily", priority: 0.6 },
    ...STATES.map((s) => ({
      url: `${base}/state/${slugify(s)}`,
      changeFrequency: "daily" as const,
      priority: 0.5,
    })),
    ...stores.map((s) => ({
      url: `${base}/store/${s.handle}`,
      changeFrequency: "daily" as const,
      priority: 0.7,
    })),
    ...products.map((p) => ({
      url: `${base}/p/${p.id}`,
      lastModified: new Date(p.created_at),
      changeFrequency: "weekly" as const,
      priority: 0.8,
    })),
  ];
}
