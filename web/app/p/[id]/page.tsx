import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { APP_NAME, naira, firstImage, getAppCtaHref } from "@/lib/format";

export const dynamic = "force-dynamic";

type Params = { params: { id: string } };

async function getProduct(id: string) {
  const { data } = await getSupabase()
    .from("products")
    .select("id, name, description, price, images, store_id")
    .eq("id", id)
    .maybeSingle();
  return data;
}

export async function generateMetadata({ params }: Params): Promise<Metadata> {
  const p = await getProduct(params.id);
  if (!p) return { title: `Product not found — ${APP_NAME}` };
  const img = firstImage(p.images);
  const description = (p.description as string) || `${naira(p.price)} on ${APP_NAME}`;
  return {
    title: `${p.name} — ${APP_NAME}`,
    description,
    openGraph: {
      title: p.name as string,
      description,
      type: "website",
      siteName: APP_NAME,
      images: img ? [img] : [],
    },
    twitter: {
      card: "summary_large_image",
      title: p.name as string,
      description,
      images: img ? [img] : [],
    },
  };
}

export default async function ProductPage({ params }: Params) {
  const p = await getProduct(params.id);
  if (!p) notFound();

  let storeName = "";
  const { data: store } = await getSupabase()
    .from("stores")
    .select("name")
    .eq("id", p.store_id)
    .maybeSingle();
  storeName = (store?.name as string) ?? "";

  const img = firstImage(p.images);
  const cta = getAppCtaHref();

  return (
    <main className="pwrap">
      <div className="card">
        {img ? <img className="img" src={img} alt={p.name as string} /> : null}
        <div className="pbody">
          <p className="price">{naira(p.price)}</p>
          <h1 className="name">{p.name}</h1>
          {storeName ? <p className="store">Sold by {storeName}</p> : null}
          {p.description ? <p className="desc">{p.description as string}</p> : null}
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
      <p className="brand">🔒 {APP_NAME} — secured with escrow protection</p>
    </main>
  );
}
