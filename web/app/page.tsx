import type { Metadata } from "next";
import { Browse } from "@/components/Browse";
import { APP_NAME } from "@/lib/format";
import { cleanQuery } from "@/lib/validate";

type Props = { searchParams: { q?: string; page?: string } };

export function generateMetadata({ searchParams }: Props): Metadata {
  const q = cleanQuery(searchParams.q);
  return {
    title: q ? `${q} — ${APP_NAME}` : `${APP_NAME} — shop trusted Nigerian vendors with escrow protection`,
    description:
      "Browse products from verified Nigerian vendors. Buy safely in the app with escrow protection and tracked delivery.",
    alternates: { canonical: "/" },
    // Search-result pages are thin/duplicate for search engines.
    robots: q || searchParams.page ? { index: false, follow: true } : undefined,
  };
}

export default function Home({ searchParams }: Props) {
  const q = cleanQuery(searchParams.q);
  return (
    <Browse
      heading={q ? `Results for "${q}"` : "Latest products"}
      basePath="/"
      q={q}
      pageParam={searchParams.page}
    />
  );
}
