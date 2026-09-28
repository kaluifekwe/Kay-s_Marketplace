import { getSupabase } from "./supabase";
import {
  PAGE_SIZE,
  cleanCategory,
  cleanQuery,
  isHandle,
  isUuid,
  likePattern,
} from "./validate";

// Every read goes to a web_public_* view. Values are validated by the caller
// (lib/validate.ts) and bound as parameters by supabase-js.

const PRODUCT_COLS =
  "id, store_id, store_handle, store_name, store_verified, state, name, description, price, images, category, created_at";
const STORE_COLS =
  "id, handle, name, description, logo_path, store_banner_url, is_verified, state, avg_rating, review_count";

export type WebProduct = {
  id: string;
  store_id: string;
  store_handle: string;
  store_name: string;
  store_verified: boolean;
  state: string | null;
  name: string;
  description: string | null;
  price: number;
  images: string;
  category: string | null;
  created_at: string;
};

export type WebStore = {
  id: string;
  handle: string;
  name: string;
  description: string | null;
  logo_path: string | null;
  store_banner_url: string | null;
  is_verified: boolean;
  state: string | null;
  avg_rating: number;
  review_count: number;
};

export async function listProducts(opts: {
  q?: string;
  category?: string;
  state?: string | null;
  page: number;
}): Promise<{ items: WebProduct[]; hasMore: boolean }> {
  const from = (opts.page - 1) * PAGE_SIZE;
  let query = getSupabase()
    .from("web_public_products")
    .select(PRODUCT_COLS)
    .order("created_at", { ascending: false })
    .range(from, from + PAGE_SIZE); // one extra row tells us if there is a next page

  const q = cleanQuery(opts.q);
  if (q) query = query.ilike("name", likePattern(q));
  const category = cleanCategory(opts.category);
  if (category) query = query.eq("category", category);
  if (opts.state) query = query.eq("state", opts.state);

  const { data } = await query;
  const rows = (data ?? []) as WebProduct[];
  return { items: rows.slice(0, PAGE_SIZE), hasMore: rows.length > PAGE_SIZE };
}

export async function getProduct(id: string): Promise<WebProduct | null> {
  if (!isUuid(id)) return null;
  const { data } = await getSupabase()
    .from("web_public_products")
    .select(PRODUCT_COLS)
    .eq("id", id)
    .maybeSingle();
  return (data as WebProduct | null) ?? null;
}

/** Look up by clean handle first, then fall back to a raw store id (old links). */
export async function getStore(handleOrId: string): Promise<WebStore | null> {
  const db = getSupabase();
  if (isHandle(handleOrId)) {
    const { data } = await db
      .from("web_public_stores")
      .select(STORE_COLS)
      .eq("handle", handleOrId)
      .maybeSingle();
    if (data) return data as WebStore;
  }
  if (isUuid(handleOrId)) {
    const { data } = await db
      .from("web_public_stores")
      .select(STORE_COLS)
      .eq("id", handleOrId)
      .maybeSingle();
    if (data) return data as WebStore;
  }
  return null;
}

export async function listStoreProducts(storeId: string): Promise<WebProduct[]> {
  if (!isUuid(storeId)) return [];
  const { data } = await getSupabase()
    .from("web_public_products")
    .select(PRODUCT_COLS)
    .eq("store_id", storeId)
    .order("created_at", { ascending: false })
    .limit(60);
  return (data ?? []) as WebProduct[];
}

export async function listStores(page: number): Promise<{ items: WebStore[]; hasMore: boolean }> {
  const from = (page - 1) * PAGE_SIZE;
  const { data } = await getSupabase()
    .from("web_public_stores")
    .select(STORE_COLS)
    .order("review_count", { ascending: false })
    .order("name", { ascending: true })
    .range(from, from + PAGE_SIZE);
  const rows = (data ?? []) as WebStore[];
  return { items: rows.slice(0, PAGE_SIZE), hasMore: rows.length > PAGE_SIZE };
}

export async function listCategories(): Promise<{ category: string; product_count: number }[]> {
  const { data } = await getSupabase()
    .from("web_public_categories")
    .select("category, product_count")
    .order("product_count", { ascending: false })
    .limit(30);
  return (data ?? []) as { category: string; product_count: number }[];
}

/** For the sitemap: newest listings only, capped. */
export async function sitemapEntries(): Promise<{
  products: { id: string; created_at: string }[];
  stores: { handle: string }[];
}> {
  const db = getSupabase();
  const [p, s] = await Promise.all([
    db.from("web_public_products").select("id, created_at").order("created_at", { ascending: false }).limit(5000),
    db.from("web_public_stores").select("handle").limit(2000),
  ]);
  return {
    products: (p.data ?? []) as { id: string; created_at: string }[],
    stores: (s.data ?? []) as { handle: string }[],
  };
}
