import { listCategories, listProducts } from "@/lib/data";
import { parsePage } from "@/lib/validate";
import { AppCta, Chips, Pager, ProductGrid, SafetyNote, SiteHeader } from "./Ui";

// One browse view used by /, /c/[category] and /state/[state].
export async function Browse({
  heading,
  basePath,
  q = "",
  category,
  state,
  pageParam,
}: {
  heading: string;
  basePath: string;
  q?: string;
  category?: string;
  state?: string | null;
  pageParam?: unknown;
}) {
  const page = parsePage(pageParam);
  const [{ items, hasMore }, categories] = await Promise.all([
    listProducts({ q, category, state, page }),
    listCategories(),
  ]);
  const params: Record<string, string> = {};
  if (q) params.q = q;

  return (
    <>
      <SiteHeader q={q} />
      <main className="swrap">
        <h1 className="sname">{heading}</h1>
        <Chips categories={categories} activeCategory={category} activeState={state} />
        <ProductGrid items={items} />
        <Pager basePath={basePath} params={params} page={page} hasMore={hasMore} />
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
