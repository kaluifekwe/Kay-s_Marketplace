import type { Metadata } from "next";
import Link from "next/link";
import { AppCta, Pager, SafetyNote, SiteHeader } from "@/components/Ui";
import { listStores } from "@/lib/data";
import { APP_NAME, safeImageUrl } from "@/lib/format";
import { parsePage } from "@/lib/validate";

export const metadata: Metadata = {
  title: `Verified stores — ${APP_NAME}`,
  description: `Browse verified Nigerian vendors on ${APP_NAME}.`,
  alternates: { canonical: "/stores" },
};

export default async function StoresPage({ searchParams }: { searchParams: { page?: string } }) {
  const page = parsePage(searchParams.page);
  const { items, hasMore } = await listStores(page);
  return (
    <>
      <SiteHeader />
      <main className="swrap">
        <h1 className="sname">Verified stores</h1>
        {items.length ? (
          <div className="grid">
            {items.map((s) => {
              const logo = safeImageUrl(s.logo_path);
              return (
                <Link className="pcard" key={s.id} href={`/store/${s.handle}`}>
                  {logo ? <img className="pimg" src={logo} alt="" loading="lazy" /> : <div className="pimg" />}
                  <div className="pcbody">
                    <p className="pcname">
                      {s.name}
                      {s.is_verified ? " ✔" : ""}
                    </p>
                    <p className="pcstore">
                      {s.state ?? ""}
                      {s.review_count > 0 ? ` · ★ ${Number(s.avg_rating).toFixed(1)}` : ""}
                    </p>
                  </div>
                </Link>
              );
            })}
          </div>
        ) : (
          <p className="empty">No stores yet.</p>
        )}
        <Pager basePath="/stores" params={{}} page={page} hasMore={hasMore} />
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
