import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import ReactMarkdown from "react-markdown";
import { AppCta, JsonLd, SafetyNote, SiteHeader } from "@/components/Ui";
import { getBlogPost, relatedBlogPosts } from "@/lib/data";
import { APP_NAME, getAppCtaHref, jsonLd, safeImageUrl, siteUrl } from "@/lib/format";

type Params = { params: Promise<{ slug: string }> };

export async function generateMetadata(props: Params): Promise<Metadata> {
  const params = await props.params;
  const post = await getBlogPost(params.slug);
  if (!post) return { title: `Not found — ${APP_NAME}`, robots: { index: false } };
  const img = safeImageUrl(post.hero_image_url);
  const description = post.meta_description || `${post.title} — ${APP_NAME}`;
  return {
    title: `${post.title} — ${APP_NAME}`,
    description: description.slice(0, 200),
    alternates: { canonical: `/blog/${post.slug}` },
    openGraph: {
      title: post.title,
      description: description.slice(0, 200),
      type: "article",
      siteName: APP_NAME,
      images: img ? [img] : [],
    },
    twitter: {
      card: "summary_large_image",
      title: post.title,
      description: description.slice(0, 200),
      images: img ? [img] : [],
    },
  };
}

export default async function BlogPostPage(props: Params) {
  const params = await props.params;
  const post = await getBlogPost(params.slug);
  if (!post) notFound();

  const [related] = await Promise.all([relatedBlogPosts(post.category, post.slug)]);
  const img = safeImageUrl(post.hero_image_url);

  // Buyer/vendor CTA copy. Links to the app for now — swaps to the
  // buyer/vendor waitlist page once that's built (separate piece of work).
  const ctaLabel =
    post.audience === "vendor"
      ? `Join the ${APP_NAME} vendor waitlist`
      : `Join the ${APP_NAME} buyer waitlist`;
  const ctaHref = getAppCtaHref();

  const structured = {
    "@context": "https://schema.org",
    "@type": "Article",
    headline: post.title,
    description: post.meta_description ?? undefined,
    image: img || undefined,
    datePublished: post.published_at,
    dateModified: post.published_at,
    url: `${siteUrl()}/blog/${post.slug}`,
    publisher: { "@type": "Organization", name: APP_NAME },
    mainEntityOfPage: { "@type": "WebPage", "@id": `${siteUrl()}/blog/${post.slug}` },
  };

  return (
    <>
      <SiteHeader />
      <main className="pwrap" style={{ maxWidth: 720 }}>
        <div className="card">
          {img ? <img className="img" src={img} alt={post.title} /> : null}
          <div className="pbody">
            {post.category ? (
              <p className="store">
                <Link href={`/blog/category/${post.category.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`}>
                  {post.category}
                </Link>
              </p>
            ) : null}
            <h1 className="name" style={{ fontSize: 28 }}>
              {post.title}
            </h1>
            <div className="article">
              <ReactMarkdown>{post.article_content}</ReactMarkdown>
            </div>

            {ctaHref ? (
              <a className="cta" href={ctaHref} rel="noopener" style={{ marginTop: 24, display: "block" }}>
                {ctaLabel}
              </a>
            ) : (
              <div className="soon" style={{ marginTop: 24 }}>
                📱 {ctaLabel}, launching soon on Google Play
              </div>
            )}
          </div>
        </div>

        {related.length ? (
          <section className="section" style={{ padding: "24px 0" }}>
            <h2 className="sectionTitle">Related reading</h2>
            <ul className="relatedList">
              {related.map((r) => (
                <li key={r.id}>
                  <Link href={`/blog/${r.slug}`}>{r.title}</Link>
                </li>
              ))}
            </ul>
          </section>
        ) : null}

        <SafetyNote />
      </main>
      <div className="bar">
        <div className="barwrap">
          <AppCta />
        </div>
      </div>
      <JsonLd data={structured} />
    </>
  );
}
