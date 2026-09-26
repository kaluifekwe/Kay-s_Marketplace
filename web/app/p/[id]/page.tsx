import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { AppCta, JsonLd, SafetyNote, SiteHeader } from "@/components/Ui";
import { getProduct } from "@/lib/data";
import { APP_NAME, imageList, naira, siteUrl } from "@/lib/format";
import { isUuid } from "@/lib/validate";

type Params = { params: Promise<{ id: string }> };

export async function generateMetadata(props: Params): Promise<Metadata> {
  const params = await props.params;
  const p = await getProduct(params.id);
  if (!p) return { title: `Product not found — ${APP_NAME}`, robots: { index: false } };
  const img = imageList(p.images)[0];
  const description = p.description || `${naira(p.price)} on ${APP_NAME}`;
  return {
    title: `${p.name} — ${naira(p.price)} — ${APP_NAME}`,
    description: description.slice(0, 200),
    alternates: { canonical: `/p/${p.id}` },
    openGraph: {
      title: p.name,
      description: description.slice(0, 200),
      type: "website",
      siteName: APP_NAME,
      images: img ? [img] : [],
    },
    twitter: {
      card: "summary_large_image",
      title: p.name,
      description: description.slice(0, 200),
      images: img ? [img] : [],
    },
  };
}

export default async function ProductPage(props: Params) {
  const params = await props.params;
  if (!isUuid(params.id)) notFound();
  const p = await getProduct(params.id);
  if (!p) notFound();

  const imgs = imageList(p.images);
  // Structured data so Google can show price and availability in results.
  // Seller is the store BRAND only; no contact details are ever included.
  const structured = {
    "@context": "https://schema.org",
    "@type": "Product",
    name: p.name,
    description: p.description ?? undefined,
    image: imgs,
    category: p.category ?? undefined,
    url: `${siteUrl()}/p/${p.id}`,
    offers: {
      "@type": "Offer",
      price: Number(p.price),
      priceCurrency: "NGN",
      availability: "https://schema.org/InStock",
      url: `${siteUrl()}/p/${p.id}`,
      seller: { "@type": "Organization", name: p.store_name },
    },
  };

  return (
    <>
      <SiteHeader />
      <main className="pwrap">
        <div className="card">
          {imgs[0] ? <img className="img" src={imgs[0]} alt={p.name} /> : null}
          {imgs.length > 1 ? (
            <div className="thumbs">
              {imgs.slice(1).map((u) => (
                <img key={u} src={u} alt="" loading="lazy" />
              ))}
            </div>
          ) : null}
          <div className="pbody">
            <p className="price">{naira(p.price)}</p>
            <h1 className="name">{p.name}</h1>
            <p className="store">
              Sold by{" "}
              <Link href={`/store/${p.store_handle}`}>
                {p.store_name}
                {p.store_verified ? " ✔" : ""}
              </Link>
              {p.state ? ` · ${p.state}` : ""}
            </p>
            {p.description ? <p className="desc">{p.description}</p> : null}
            <AppCta label={`Buy in the ${APP_NAME} app`} />
          </div>
        </div>
        <SafetyNote />
      </main>
      <JsonLd data={structured} />
    </>
  );
}
