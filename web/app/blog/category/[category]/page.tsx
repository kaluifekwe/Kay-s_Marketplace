import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { AppCta, SafetyNote, SiteHeader } from "@/components/Ui";
import { WaitlistForm } from "@/components/WaitlistForm";
import { listBlogCategories, listBlogPosts } from "@/lib/data";
import { APP_NAME, safeBlogImageUrl } from "@/lib/format";
import { parsePage, slugify } from "@/lib/validate";

type Props = { params: Promise<{ category: string }>; searchParams: Promise<{ page?: string }> };

async function resolve(slug: string): Promise<string | null> {
  if (!/^[a-z0-9-]{1,60}$/.test(slug)) return null;
  const cats = await listBlogCategories();
  return cats.find((c) => slugify(c) === slug) ?? null;
}

export async function generateMetadata(props: Props): Promise<Metadata> {
  const params = await props.params;
  const category = await resolve(params.category);
  if (!category) return { title: `Not found — ${APP_NAME}`, robots: { index: false } };
  return {
    title: `${category} — Blog — ${APP_NAME}`,
    description: `Articles about ${category.toLowerCase()} from ${APP_NAME}.`,
    alternates: { canonical: `/blog/category/${params.category}` },
  };
}

export default async function BlogCategoryPage(props: Props) {
  const [params, searchParams] = await Promise.all([props.params, props.searchParams]);
  const category = await resolve(params.category);
  if (!category) notFound();

  const page = parsePage(searchParams.page);
  const { items, hasMore } = await listBlogPosts({ category, page });

  return (
    <>
      <SiteHeader />
      <main className="swrap">
        <h1 className="sname">{category}</h1>
        <p className="sdesc">
          <Link href="/blog">← All posts</Link>
        </p>

        {items.length ? (
          <div className="blogGrid">
            {items.map((post) => {
              const img = safeBlogImageUrl(post.hero_image_url);
              return (
                <Link key={post.id} href={`/blog/${post.slug}`} className="blogCard">
                  {img ? <img className="blogImg" src={img} alt={post.title} loading="lazy" /> : <div className="blogImg" />}
                  <div className="blogBody">
                    <p className="blogTitle">{post.title}</p>
                    {post.meta_description ? <p className="blogExcerpt">{post.meta_description}</p> : null}
                  </div>
                </Link>
              );
            })}
          </div>
        ) : (
          <p className="empty">No posts in this category yet.</p>
        )}

        {page > 1 || hasMore ? (
          <nav className="pager" aria-label="Pages">
            {page > 1 ? (
              <Link href={page === 2 ? `/blog/category/${params.category}` : `/blog/category/${params.category}?page=${page - 1}`}>← Previous</Link>
            ) : (
              <span />
            )}
            <span>Page {page}</span>
            {hasMore ? <Link href={`/blog/category/${params.category}?page=${page + 1}`}>Next →</Link> : <span />}
          </nav>
        ) : null}

        <section className="section" style={{ padding: "24px 0" }}>
          <h2 className="sectionTitle">Get early access</h2>
          <WaitlistForm />
        </section>

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
