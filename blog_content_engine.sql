-- Blog / content-marketing engine (Kay's Market SEO growth engine, Phase 1).
--
-- Security model matches the public web storefront exactly (see
-- web_public_views.sql): the drafting/research table is admin-only, never
-- touched by the anon key; the public site reads ONLY a narrow, published-only
-- view. A draft, its research notes, its SEO score, and its unpublished social
-- copy are never public, regardless of what a future bug in the web app might
-- try to read.
--
-- Safe to re-run.

-- ── 1. The content queue (admin-only) ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS content_items (
  id                  uuid primary key default uuid_generate_v4(),

  -- research (section 3/4 of the plan)
  topic               text not null,
  keyword             text,
  search_intent       text check (search_intent in ('informational','commercial','transactional','vendor')),
  audience            text not null check (audience in ('buyer','vendor')),
  state               text,              -- Nigerian state this topic targets, if any
  category            text,              -- e.g. 'buying-online','selling-online','safety'
  source              text,              -- 'google-search','manual-research', etc. Never a scraped platform.
  source_url          text,
  research_summary    text,              -- the real pain point, in the researcher's own words

  -- pipeline state (section 11)
  content_status      text not null default 'DISCOVERED'
                        check (content_status in (
                          'DISCOVERED','RESEARCHING','DRAFTED','REVIEW',
                          'APPROVED','PUBLISHED','UPDATED','REJECTED'
                        )),
  priority            int not null default 0,
  seo_score           int,               -- filled by the SEO validation step before REVIEW

  -- the generated article
  article_title       text,
  slug                text,
  meta_description    text,
  article_content     text,              -- markdown
  hero_image_url      text,              -- Unsplash photo, or a real vendor/product photo

  -- generated social variants (section 6) — copy-paste source only, never
  -- auto-posted (see the "free and manual" distribution decision)
  social_facebook     text,
  social_instagram    text,
  social_x            text,
  social_linkedin     text,
  social_whatsapp_status text,

  published_at        timestamptz,
  created_by           uuid references users(id),
  approved_by           uuid references users(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

CREATE INDEX IF NOT EXISTS idx_content_items_status ON content_items(content_status);
CREATE INDEX IF NOT EXISTS idx_content_items_audience ON content_items(audience);
CREATE UNIQUE INDEX IF NOT EXISTS uniq_content_items_slug ON content_items(slug) WHERE slug IS NOT NULL;

ALTER TABLE content_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS content_items_admin_all ON content_items;
CREATE POLICY content_items_admin_all ON content_items
  FOR ALL USING (is_admin()) WITH CHECK (is_admin());

-- No grant to anon or authenticated: only service_role (the admin app's Edge
-- Functions) and the admin RLS policy above can touch this table.
REVOKE ALL ON content_items FROM PUBLIC, anon, authenticated;
GRANT ALL ON content_items TO service_role;
GRANT SELECT, INSERT, UPDATE ON content_items TO authenticated; -- gated by the RLS policy (admins only)

-- ── 2. The public read: published posts only, safe columns only ─────────────
-- Same shape as web_public_products/web_public_stores: no research notes, no
-- SEO score, no unpublished social copy, no internal source attribution.
DROP VIEW IF EXISTS web_public_blog_posts;
CREATE VIEW web_public_blog_posts WITH (security_barrier = true) AS
SELECT
  id,
  article_title       AS title,
  slug,
  meta_description,
  article_content,
  hero_image_url,
  category,
  audience,
  state,
  published_at
FROM content_items
WHERE content_status = 'PUBLISHED'
  AND slug IS NOT NULL
  AND article_content IS NOT NULL;

REVOKE ALL ON web_public_blog_posts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON web_public_blog_posts TO anon, authenticated;

CREATE INDEX IF NOT EXISTS idx_content_items_published
  ON content_items (published_at DESC)
  WHERE content_status = 'PUBLISHED';

-- ── 3. Verify (expect the results in the comments) ───────────────────────────
--   -- anon cannot read content_items directly (expect 0 rows):
--   SELECT table_name FROM information_schema.role_table_grants
--   WHERE grantee='anon' AND table_schema='public' AND table_name='content_items';
--   -- anon CAN read the published view (expect 1 row):
--   SELECT table_name FROM information_schema.role_table_grants
--   WHERE grantee='anon' AND table_schema='public' AND table_name='web_public_blog_posts';
--   -- the view exposes no research/internal columns (expect 0 rows):
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='web_public_blog_posts'
--     AND column_name IN ('topic','keyword','research_summary','source','source_url',
--                          'seo_score','priority','social_facebook','social_instagram',
--                          'social_x','social_linkedin','social_whatsapp_status','created_by','approved_by');

-- ── Roll back ─────────────────────────────────────────────────────────────
--   DROP VIEW IF EXISTS web_public_blog_posts;
--   DROP TABLE IF EXISTS content_items;
