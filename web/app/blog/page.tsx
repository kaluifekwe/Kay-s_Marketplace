import type { Metadata } from "next";
import Link from "next/link";
import { AppCta, SafetyNote, SiteHeader } from "@/components/Ui";
import { WaitlistForm } from "@/components/WaitlistForm";
import { listBlogCategories, listBlogPosts } from "@/lib/data";
import { APP_NAME, getAppCtaHref, safeBlogImageUrl } from "@/lib/format";
import { parsePage, slugify } from "@/lib/validate";

type Props = { searchParams: Promise<{ page?: string }> };

export const metadata: Metadata = {
  title: `Blog — ${APP_NAME}`,
  description:
    "Buying and selling online in Nigeria: escrow safety, avoiding scams, delivery, and practical advice for vendors and buyers.",
  alternates: { canonical: "/blog" },
};

export default async function BlogIndex(props: Props) {
  const searchParams = await props.searchParams;
  const page = parsePage(searchParams.page);
  const [{ items, hasMore }, categories] = await Promise.all([
    listBlogPosts({ page }),
    listBlogCategories(),
  ]);

  return (
    <>
      <SiteHeader />
      <main className="swrap">
        <h1 className="sname">Blog</h1>
        <p className="sdesc">Buying and selling online in Nigeria, explained plainly.</p>

        {categories.length ? (
          <div className="chips" aria-label="Blog categories">
            <Link href="/blog" className="chip on">
              All
            </Link>
            {categories.map((c) => (
              <Link key={c} href={`/blog/category/${slugify(c)}`} className="chip">
                {c}
              </Link>
            ))}
          </div>
        ) : null}

        {items.length ? (
          <div className="blogGrid">
            {items.map((post) => {
              const img = safeBlogImageUrl(post.hero_image_url);
              return (
                <Link key={post.id} href={`/blog/${post.slug}`} className="blogCard">
                  {img ? <img className="blogImg" src={img} alt={post.title} loading="lazy" /> : <div className="blogImg" />}
                  <div className="blogBody">
                    {post.category ? <span className="blogCat">{post.category}</span> : null}
                    <p className="blogTitle">{post.title}</p>
                    {post.meta_description ? <p className="blogExcerpt">{post.meta_description}</p> : null}
                  </div>
                </Link>
              );
            })}
          </div>
        ) : (
          <p className="empty">No posts yet, check back soon.</p>
        )}

        {page > 1 || hasMore ? (
          <nav className="pager" aria-label="Pages">
            {page > 1 ? <Link href={page === 2 ? "/blog" : `/blog?page=${page - 1}`}>← Previous</Link> : <span />}
            <span>Page {page}</span>
            {hasMore ? <Link href={`/blog?page=${page + 1}`}>Next →</Link> : <span />}
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
          {getAppCtaHref() ? (
            <AppCta />
          ) : (
            <a className="cta" href="#waitlist">
              📩 Join the waitlist
            </a>
          )}
        </div>
      </div>
    </>
  );
}
