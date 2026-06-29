import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { APP_NAME, naira, firstImage, getAppCtaHref } from "@/lib/format";

export const dynamic = "force-dynamic";

type Params = { params: { handle: string } };

const STORE_FIELDS =
  "id, name, description, logo_path, store_banner_url, is_verified, address";

// Look up by clean handle first, then fall back to a raw store id.
async function getStore(handleOrId: string) {
  const db = getSupabase();
  const byHandle = await db
    .from("stores")
    .select(STORE_FIELDS)
    .eq("handle", handleOrId.toLowerCase())
    .maybeSingle();
  if (byHandle.data) return byHandle.data;
  const byId = await db
    .from("stores")
    .select(STORE_FIELDS)
    .eq("id", handleOrId)
    .maybeSingle();
  return byId.data;
}

async function getProducts(storeId: string) {
  const { data } = await getSupabase()
    .from("products")
    .select("id, name, price, images")
    .eq("store_id", storeId)
    .order("created_at", { ascending: false })
    .limit(60);
  return data ?? [];
}

export async function generateMetadata({ params }: Params): Promise<Metadata> {
  const store = await getStore(params.handle);
  if (!store) return { title: `Store not found — ${APP_NAME}` };
  const description =
    (store.description as string) ||
    `Shop ${store.name} on ${APP_NAME} — secured with escrow protection.`;
  const img =
    (store.store_banner_url as string) || (store.logo_path as string) || "";
  return {
    title: `${store.name} — ${APP_NAME}`,
    description,
    openGraph: {
      title: store.name as string,
      description,
      type: "website",
      siteName: APP_NAME,
      images: img ? [img] : [],
    },
    twitter: {
      card: "summary_large_image",
      title: store.name as string,
      description,
      images: img ? [img] : [],
    },
  };
}

export default async function StorePage({ params }: Params) {
  const store = await getStore(params.handle);
  if (!store) notFound();

  const products = await getProducts(store.id as string);
  const banner = (store.store_banner_url as string) || "";
  const logo = (store.logo_path as string) || "";
  const cta = getAppCtaHref();

  return (
    <>
      <main className="swrap">
        {banner ? (
          <img className="banner" src={banner} alt={store.name as string} />
        ) : null}
        <div className="head">
          <div className="logo">
            {logo ? (
              <img
                src={logo}
                alt=""
                style={{ width: "100%", height: "100%", objectFit: "cover", borderRadius: 14 }}
              />
            ) : (
              "🏪"
            )}
          </div>
          <div>
            <h1 className="sname">
              {store.name}
              {store.is_verified ? (
                <span className="verified" title="Verified">
                  ✔
                </span>
              ) : null}
            </h1>
            {store.description ? (
              <p className="sdesc">{store.description as string}</p>
            ) : null}
            {store.address ? (
              <p className="saddr">📍 {store.address as string}</p>
            ) : null}
          </div>
        </div>

        <p className="count">
          {products.length} {products.length === 1 ? "item" : "items"}
        </p>

        {products.length ? (
          <div className="grid">
            {products.map((p: any) => {
              const img = firstImage(p.images);
              return (
                <a className="pcard" key={p.id} href={`/p/${p.id}`}>
                  {img ? (
                    <img className="pimg" src={img} alt={p.name} loading="lazy" />
                  ) : (
                    <div className="pimg" />
                  )}
                  <div className="pcbody">
                    <p className="pcname">{p.name}</p>
                    <p className="pcprice">{naira(p.price)}</p>
                  </div>
                </a>
              );
            })}
          </div>
        ) : (
          <p className="empty">No products listed yet.</p>
        )}
      </main>

      <div className="bar">
        <div className="barwrap">
          {cta ? (
            <a className="cta" href={cta}>
              Get the {APP_NAME} app to buy
            </a>
          ) : (
            <div className="soon">
              📱 Buy securely in the {APP_NAME} app — launching soon on Google Play
            </div>
          )}
        </div>
      </div>
    </>
  );
}
