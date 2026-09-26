import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Browse } from "@/components/Browse";
import { APP_NAME } from "@/lib/format";
import { parseState, slugify } from "@/lib/validate";

type Props = { params: { state: string }; searchParams: { page?: string } };

export function generateMetadata({ params }: Props): Metadata {
  const state = parseState(params.state);
  if (!state) return { title: `Not found — ${APP_NAME}`, robots: { index: false } };
  return {
    title: `Shop in ${state} — ${APP_NAME}`,
    description: `Products from verified vendors in ${state}, Nigeria. Buy safely in the app with escrow protection.`,
    alternates: { canonical: `/state/${slugify(state)}` },
  };
}

export default function StatePage({ params, searchParams }: Props) {
  const state = parseState(params.state);
  if (!state) notFound();
  return (
    <Browse
      heading={`Shop in ${state}`}
      basePath={`/state/${slugify(state)}`}
      state={state}
      pageParam={searchParams.page}
    />
  );
}
