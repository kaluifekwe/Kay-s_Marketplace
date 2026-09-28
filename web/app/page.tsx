import type { Metadata } from "next";
import { Browse } from "@/components/Browse";
import { FeaturedVendor } from "@/components/FeaturedVendor";
import { Hero } from "@/components/Hero";
import { StatePicker } from "@/components/StatePicker";
import { AppCta, ProductGrid, SafetyNote, SiteHeader } from "@/components/Ui";
import { TrustStrip } from "@/components/TrustStrip";
import { listProducts } from "@/lib/data";
import { APP_NAME, getAppCtaHref } from "@/lib/format";
import { cleanQuery } from "@/lib/validate";

type Props = { searchParams: Promise<{ q?: string; page?: string }> };

export async function generateMetadata(props: Props): Promise<Metadata> {
  const searchParams = await props.searchParams;
  const q = cleanQuery(searchParams.q);
  return {
    title: q ? `${q} — ${APP_NAME}` : `${APP_NAME} — escrow-protected marketplace, delivered within your state`,
    description:
      "Browse products from ID-verified Nigerian vendors. Every order is escrow-protected and delivered within your own state. Buy safely in the app.",
    alternates: { canonical: "/" },
    // Search-result pages are thin/duplicate for search engines.
    robots: q || searchParams.page ? { index: false, follow: true } : undefined,
  };
}

export default async function Home(props: Props) {
  const searchParams = await props.searchParams;
  const q = cleanQuery(searchParams.q);

  // A search query keeps the plain results view (no marketing sections).
  if (q || searchParams.page) {
    return (
      <Browse
        heading={q ? `Results for "${q}"` : "Latest products"}
        basePath="/"
        q={q}
        pageParam={searchParams.page}
      />
    );
  }

  const { items: latest } = await listProducts({ page: 1 });

  return (
    <>
      <SiteHeader />
      <main>
        <div style={{ maxWidth: 1240, margin: "20px auto 0", padding: "0 24px", width: "100%" }}>
          <Hero ctaHref={getAppCtaHref()} />
        </div>

        <div style={{ maxWidth: 1240, margin: "16px auto 0", padding: "0 24px", width: "100%" }}>
          <TrustStrip />
        </div>

        <StatePicker />
        <FeaturedVendor />

        <section className="section" aria-label="Latest products">
          <div className="sectionHead">
            <h2 className="sectionTitle">Latest from verified vendors</h2>
          </div>
          <ProductGrid items={latest.slice(0, 8)} />
        </section>

        <div className="whyBand">
          <div className="whyWrap">
            <div className="whyItem">
              <div className="whyStat">100%</div>
              <div className="whySub">Orders held in escrow until confirmed</div>
            </div>
            <div className="whyItem">
              <div className="whyStat">Same-day</div>
              <div className="whySub">Delivery available within your state</div>
            </div>
            <div className="whyItem">
              <div className="whyStat">ID-verified</div>
              <div className="whySub">Every vendor checked before listing</div>
            </div>
          </div>
        </div>

        <SafetyNote />
      </main>
      <div className="bar">
        <div className="barwrap">
          <AppCta />
        </div>
      </div>
    </>
  );
}
