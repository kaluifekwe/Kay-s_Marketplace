import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Browse } from "@/components/Browse";
import { listCategories } from "@/lib/data";
import { APP_NAME } from "@/lib/format";
import { slugify } from "@/lib/validate";

type Props = { params: { category: string }; searchParams: { page?: string } };

// Resolve the URL slug against real categories only; unknown slugs 404.
async function resolve(slug: string): Promise<string | null> {
  if (!/^[a-z0-9-]{1,60}$/.test(slug)) return null;
  const cats = await listCategories();
  return cats.find((c) => slugify(c.category) === slug)?.category ?? null;
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const category = await resolve(params.category);
  if (!category) return { title: `Not found — ${APP_NAME}`, robots: { index: false } };
  return {
    title: `${category} — ${APP_NAME}`,
    description: `Shop ${category} from verified Nigerian vendors on ${APP_NAME}. Escrow-protected.`,
    alternates: { canonical: `/c/${params.category}` },
  };
}

export default async function CategoryPage({ params, searchParams }: Props) {
  const category = await resolve(params.category);
  if (!category) notFound();
  return (
    <Browse
      heading={category}
      basePath={`/c/${params.category}`}
      category={category}
      pageParam={searchParams.page}
    />
  );
}
