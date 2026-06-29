-- Store handle: a short, human-readable, unique slug for each store so vendors
-- can share a clean storefront link (…/store/chibueze-stores) instead of a UUID.
-- Auto-generated from the store name; editable later. Safe to run multiple times.

ALTER TABLE stores ADD COLUMN IF NOT EXISTS handle TEXT;

-- Backfill existing stores: slugify the name, and de-duplicate within the
-- backfill by appending a counter to the 2nd+ store that slugifies the same.
WITH slugged AS (
  SELECT
    id,
    COALESCE(
      NULLIF(trim(both '-' from regexp_replace(lower(COALESCE(name, 'store')), '[^a-z0-9]+', '-', 'g')), ''),
      'store'
    ) AS base_slug
  FROM stores
  WHERE handle IS NULL OR handle = ''
),
ranked AS (
  SELECT id, base_slug,
         row_number() OVER (PARTITION BY base_slug ORDER BY id) AS rn
  FROM slugged
)
UPDATE stores s
SET handle = CASE WHEN r.rn = 1 THEN r.base_slug ELSE r.base_slug || '-' || r.rn END
FROM ranked r
WHERE s.id = r.id;

-- Enforce uniqueness going forward (case-insensitive handles are stored
-- lower-case by the app, so a plain unique index is enough).
CREATE UNIQUE INDEX IF NOT EXISTS uniq_store_handle ON stores(handle);
