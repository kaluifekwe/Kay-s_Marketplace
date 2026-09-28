-- Public web storefront: read-only, privacy-safe views.
--
-- THREAT MODEL (see chat 2026-09-26): the web app must be unable to reach
-- anything a stranger should not see, even if the web app is fully compromised.
-- So the web app uses ONLY the anon key and ONLY these views. The database, not
-- the page code, decides what is public:
--   * never exposes: phone, whatsapp, street address, vendor_id / user ids,
--     email, KYC, stock counts, anything from users
--   * only KYC-verified, non-flagged vendors; in-stock products; not web_hidden
--   * free text (names, descriptions) has phone numbers / links / emails masked,
--     so vendors cannot use the public site to be contacted off-platform
--
-- Safe to re-run. Run in the Supabase SQL editor (each Run is its own txn).
-- Roll back: see the bottom of this file.

-- ── 1. Admin "hide from web" switch (vendors cannot flip it) ────────────────
ALTER TABLE stores   ADD COLUMN IF NOT EXISTS web_hidden boolean NOT NULL DEFAULT false;
ALTER TABLE products ADD COLUMN IF NOT EXISTS web_hidden boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION guard_web_hidden()
RETURNS trigger AS $$
BEGIN
  -- service_role / SQL editor (no client JWT role) / admins may set it.
  -- Any other client (a vendor editing their own row) cannot.
  IF auth.role() IN ('anon', 'authenticated') AND NOT is_admin() THEN
    IF TG_OP = 'INSERT' THEN
      NEW.web_hidden := false;
    ELSE
      NEW.web_hidden := OLD.web_hidden;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS guard_stores_web_hidden ON stores;
CREATE TRIGGER guard_stores_web_hidden
  BEFORE INSERT OR UPDATE OF web_hidden ON stores
  FOR EACH ROW EXECUTE FUNCTION guard_web_hidden();

DROP TRIGGER IF EXISTS guard_products_web_hidden ON products;
CREATE TRIGGER guard_products_web_hidden
  BEFORE INSERT OR UPDATE OF web_hidden ON products
  FOR EACH ROW EXECUTE FUNCTION guard_web_hidden();

-- ── 2. Mask contact details in vendor-written text ──────────────────────────
-- Removes links (incl. wa.me / t.me), emails, and any run of 9+ digits (phone
-- numbers, with or without spaces/dashes/+). Not bulletproof against spelled-out
-- digits; that is a known limit, mitigated by the app's own listing checks.
CREATE OR REPLACE FUNCTION web_scrub(t text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT nullif(btrim(
    regexp_replace(
    regexp_replace(
    regexp_replace(
      coalesce(t, ''),
      '(https?://|www\.|wa\.me/|t\.me/|bit\.ly/)\S+', '', 'gi'),
      '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '', 'gi'),
      '(\+?\d[\s.\-()]*){9,}', '', 'g')
  ), '');
$$;

-- ── 3. The views ────────────────────────────────────────────────────────────
-- Views run as their owner (bypass RLS on purpose) but expose ONLY the columns
-- and rows below. security_barrier stops query predicates leaking hidden rows.
DROP VIEW IF EXISTS web_public_categories;
DROP VIEW IF EXISTS web_public_products;
DROP VIEW IF EXISTS web_public_stores;

CREATE VIEW web_public_stores WITH (security_barrier = true) AS
SELECT
  s.id,
  s.handle,
  s.name,
  NULL::text                            AS description, -- vendors type street addresses here; never public
  s.logo_path,
  s.store_banner_url,
  COALESCE(s.is_verified, false)        AS is_verified,
  u.state                               AS state,       -- state only, no street/LGA
  COALESCE(r.avg_rating, 0)             AS avg_rating,
  COALESCE(r.review_count, 0)           AS review_count
FROM stores s
JOIN users u ON u.id = s.vendor_id
LEFT JOIN LATERAL (
  SELECT round(avg(rating)::numeric, 1) AS avg_rating, count(*)::int AS review_count
  FROM reviews WHERE store_id = s.id
) r ON true
WHERE s.web_hidden = false
  AND s.handle IS NOT NULL AND s.handle <> ''
  AND u.role = 'vendor'
  AND u.kyc_status = 'verified'
  AND COALESCE(u.vendor_flagged, false) = false
  AND COALESCE(u.dispute_flagged, false) = false;

CREATE VIEW web_public_products WITH (security_barrier = true) AS
SELECT
  p.id,
  p.store_id,
  ws.handle                                   AS store_handle,
  ws.name                                     AS store_name,
  ws.is_verified                              AS store_verified,
  ws.state                                    AS state,
  left(COALESCE(web_scrub(p.name), 'Item'), 200) AS name,
  left(web_scrub(p.description), 2000)        AS description,
  p.price::numeric                            AS price,
  p.images,
  p.category,
  p.created_at
FROM products p
JOIN web_public_stores ws ON ws.id = p.store_id
WHERE p.web_hidden = false
  AND p.stock > 0
  AND p.price > 0;

CREATE VIEW web_public_categories WITH (security_barrier = true) AS
SELECT category, count(*)::int AS product_count
FROM web_public_products
WHERE category IS NOT NULL AND category <> ''
GROUP BY category;

-- ── 4. Grants: read-only, these views only ──────────────────────────────────
REVOKE ALL ON web_public_stores, web_public_products, web_public_categories
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON web_public_stores, web_public_products, web_public_categories
  TO anon, authenticated;

-- Keep the browse query fast (the web site paginates newest-first).
CREATE INDEX IF NOT EXISTS idx_products_web_browse
  ON products (created_at DESC)
  WHERE web_hidden = false AND stock > 0;
CREATE INDEX IF NOT EXISTS idx_products_store_created
  ON products (store_id, created_at DESC);

-- ── 5. Verify (run these after; expect the results in the comments) ─────────
-- No contact/identity columns in the views (expect 0 rows):
--   SELECT table_name, column_name FROM information_schema.columns
--   WHERE table_schema='public' AND table_name LIKE 'web_public_%'
--     AND column_name IN ('phone','whatsapp_number','address','vendor_id','email','nin','kyc_status','stock');
-- Scrubber works (expect 'Call me' or similar with the number removed):
--   SELECT web_scrub('Call me 0803 123 4567 or wa.me/2348031234567 or a@b.com');
-- Anon can read the views but a hidden/unverified vendor never appears.

-- ── Roll back ───────────────────────────────────────────────────────────────
--   DROP VIEW IF EXISTS web_public_categories, web_public_products, web_public_stores;
--   DROP FUNCTION IF EXISTS web_scrub(text);
--   DROP TRIGGER IF EXISTS guard_stores_web_hidden ON stores;
--   DROP TRIGGER IF EXISTS guard_products_web_hidden ON products;
--   DROP FUNCTION IF EXISTS guard_web_hidden();
--   (columns web_hidden can stay; they are harmless.)
