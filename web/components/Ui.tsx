import Link from "next/link";
import { APP_NAME, firstImage, getAppCtaHref, naira } from "@/lib/format";
import { STATES, slugify } from "@/lib/validate";
import type { WebProduct } from "@/lib/data";

export function SiteHeader({ q = "" }: { q?: string }) {
  return (
    <header className="top">
      <div className="topwrap">
        <Link href="/" className="tlogo">
          {APP_NAME}
        </Link>
        {/* Plain GET form: no JS, no state, nothing to submit but a search word. */}
        <form action="/" method="get" className="search" role="search">
          <input
            name="q"
            defaultValue={q}
            maxLength={60}
            placeholder="Search products"
            aria-label="Search products"
            autoComplete="off"
          />
          <button type="submit">Search</button>
        </form>
        <nav className="tnav">
          <Link href="/stores">Stores</Link>
        </nav>
      </div>
    </header>
  );
}

export function AppCta({ label }: { label?: string }) {
  const cta = getAppCtaHref();
  const text = label ?? `Get the ${APP_NAME} app to buy`;
  return cta ? (
    <a className="cta" href={cta} rel="noopener">
      {text}
    </a>
  ) : (
    <div className="soon">📱 Buy securely in the {APP_NAME} app, launching soon on Google Play</div>
  );
}

export function SafetyNote() {
  return (
    <p className="note">
      🔒 Payments and delivery happen only inside the {APP_NAME} app, protected by escrow. This
      website never asks for payment, phone numbers or passwords.
    </p>
  );
}

export function ProductGrid({ items }: { items: WebProduct[] }) {
  if (!items.length) return <p className="empty">No products found.</p>;
  return (
    <div className="grid">
      {items.map((p) => {
        const img = firstImage(p.images);
        return (
          <Link className="pcard" key={p.id} href={`/p/${p.id}`}>
            {img ? (
              <img className="pimg" src={img} alt={p.name} loading="lazy" />
            ) : (
              <div className="pimg" />
            )}
            <div className="pcbody">
              <p className="pcname">{p.name}</p>
              <p className="pcprice">{naira(p.price)}</p>
              <p className="pcstore">
                {p.store_name}
                {p.store_verified ? " ✔" : ""}
                {p.state ? ` · ${p.state}` : ""}
              </p>
            </div>
          </Link>
        );
      })}
    </div>
  );
}

export function Chips({
  categories,
  activeCategory,
  activeState,
}: {
  categories: { category: string; product_count: number }[];
  activeCategory?: string;
  activeState?: string | null;
}) {
  return (
    <>
      {categories.length ? (
        <div className="chips" aria-label="Categories">
          <Link href="/" className={!activeCategory ? "chip on" : "chip"}>
            All
          </Link>
          {categories.map((c) => (
            <Link
              key={c.category}
              href={`/c/${encodeURIComponent(slugify(c.category))}`}
              className={activeCategory === c.category ? "chip on" : "chip"}
            >
              {c.category}
            </Link>
          ))}
        </div>
      ) : null}
      <div className="chips" aria-label="States">
        {STATES.map((s) => (
          <Link
            key={s}
            href={`/state/${slugify(s)}`}
            className={activeState === s ? "chip on" : "chip"}
          >
            {s}
          </Link>
        ))}
      </div>
    </>
  );
}

export function Pager({
  basePath,
  params,
  page,
  hasMore,
}: {
  basePath: string;
  params: Record<string, string>;
  page: number;
  hasMore: boolean;
}) {
  const href = (n: number) => {
    const sp = new URLSearchParams(params);
    if (n > 1) sp.set("page", String(n));
    const qs = sp.toString();
    return qs ? `${basePath}?${qs}` : basePath;
  };
  if (page <= 1 && !hasMore) return null;
  return (
    <nav className="pager" aria-label="Pages">
      {page > 1 ? <Link href={href(page - 1)}>← Previous</Link> : <span />}
      <span>Page {page}</span>
      {hasMore ? <Link href={href(page + 1)}>Next →</Link> : <span />}
    </nav>
  );
}
