import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { AppCta, ProductGrid, SafetyNote, SiteHeader } from "@/components/Ui";
import { getStore, listStoreProducts } from "@/lib/data";
import { APP_NAME, jsonLd, safeImageUrl, siteUrl } from "@/lib/format";

type Params = { params: Promise<{ handle: string }> };

export async function generateMetadata(props: Params): Promise<Metadata> {
  const params = await props.params;
  const store = await getStore(params.handle);
  if (!store) return { title: `Store not found — ${APP_NAME}`, robots: { index: false } };
  const description =
    store.description || `Shop ${store.name} on ${APP_NAME}, secured with escrow protection.`;
  const img = safeImageUrl(store.store_banner_url) || safeImageUrl(store.logo_path);
  return {
    title: `${store.name} — ${APP_NAME}`,
    description: description.slice(0, 200),
    alternates: { canonical: `/store/${store.handle}` },
    openGraph: {
      title: store.name,
      description: description.slice(0, 200),
      type: "website",
      siteName: APP_NAME,
      images: img ? [img] : [],
    },
    twitter: {
      card: "summary_large_image",
      title: store.name,
      description: description.slice(0, 200),
      images: img ? [img] : [],
    },
  };
}

export default async function StorePage(props: Params) {
  const params = await props.params;
  const store = await getStore(params.handle);
  if (!store) notFound();

  const products = await listStoreProducts(store.id);
  const banner = safeImageUrl(store.store_banner_url);
  const logo = safeImageUrl(store.logo_path);

  // Brand-level data only. No address, phone or owner details exist in the view.
  const structured = {
    "@context": "https://schema.org",
    "@type": "Store",
    name: store.name,
    url: `${siteUrl()}/store/${store.handle}`,
    image: banner || logo || undefined,
    description: store.description ?? undefined,
    ...(store.review_count > 0
      ? {
          aggregateRating: {
            "@type": "AggregateRating",
            ratingValue: Number(store.avg_rating),
            reviewCount: store.review_count,
          },
        }
      : {}),
  };

  return (
    <>
      <SiteHeader />
      <main className="swrap">
        {banner ? <img className="banner" src={banner} alt={store.name} /> : null}
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
            {store.description ? <p className="sdesc">{store.description}</p> : null}
            <p className="saddr">
              {store.state ? `📍 ${store.state}` : ""}
              {store.review_count > 0
                ? `${store.state ? " · " : ""}★ ${Number(store.avg_rating).toFixed(1)} (${store.review_count})`
                : ""}
            </p>
          </div>
        </div>

        <p className="count">
          {products.length} {products.length === 1 ? "item" : "items"}
        </p>
        <ProductGrid items={products} />
        <SafetyNote />
      </main>

      <div className="bar">
        <div className="barwrap">
          <AppCta />
        </div>
      </div>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(structured) }}
      />
    </>
  );
}
