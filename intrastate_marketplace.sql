-- ============================================
-- Intrastate marketplace — buyers can only purchase
-- from vendors in their own state.
--
-- NOTE: this codebase uses `users` (not `profiles`) and `products` links
-- to its vendor via store_id -> stores.vendor_id (there is no
-- products.vendor_id column) — adapted accordingly from the original spec.
-- ============================================

-- 1. State / LGA on users (covers both buyers and vendors)
ALTER TABLE users ADD COLUMN IF NOT EXISTS state TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS lga TEXT;

-- 2. Denormalized vendor_state on products (avoids a join on every
--    marketplace browse query at 30k-user scale)
ALTER TABLE products ADD COLUMN IF NOT EXISTS vendor_state TEXT;

CREATE INDEX IF NOT EXISTS idx_products_vendor_state ON products(vendor_state);
CREATE INDEX IF NOT EXISTS idx_users_state ON users(state);

-- 3. Auto-fill vendor_state on insert/update via store_id -> stores.vendor_id -> users.state
CREATE OR REPLACE FUNCTION set_product_vendor_state()
RETURNS TRIGGER AS $$
BEGIN
  SELECT u.state INTO NEW.vendor_state
  FROM stores s
  JOIN users u ON u.id = s.vendor_id
  WHERE s.id = NEW.store_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS auto_set_product_vendor_state ON products;
CREATE TRIGGER auto_set_product_vendor_state
BEFORE INSERT OR UPDATE OF store_id ON products
FOR EACH ROW
EXECUTE FUNCTION set_product_vendor_state();

-- 4. Backfill vendor_state for existing products
UPDATE products p
SET vendor_state = u.state
FROM stores s
JOIN users u ON u.id = s.vendor_id
WHERE p.store_id = s.id
  AND p.vendor_state IS DISTINCT FROM u.state;
