-- Adds photographer attribution for auto-picked Unsplash hero images.
-- Unsplash's API guidelines require crediting the photographer and Unsplash
-- wherever a photo is shown — see generate-blog-draft/index.ts and
-- web/app/blog/[slug]/page.tsx for where these get displayed.
--
-- Safe to re-run.

ALTER TABLE content_items ADD COLUMN IF NOT EXISTS hero_image_credit text;
ALTER TABLE content_items ADD COLUMN IF NOT EXISTS hero_image_credit_url text;

-- Re-create the public view to include the two new columns (same pattern as
-- blog_content_engine.sql — narrow, published-only, no internal columns).
DROP VIEW IF EXISTS web_public_blog_posts;
CREATE VIEW web_public_blog_posts WITH (security_barrier = true) AS
SELECT
  id,
  article_title       AS title,
  slug,
  meta_description,
  article_content,
  hero_image_url,
  hero_image_credit,
  hero_image_credit_url,
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

-- ── Roll back ──────────────────────────────────────────────────────────────
--   ALTER TABLE content_items DROP COLUMN IF EXISTS hero_image_credit;
--   ALTER TABLE content_items DROP COLUMN IF EXISTS hero_image_credit_url;
--   (then re-run blog_content_engine.sql's view definition to drop the columns from the view)
