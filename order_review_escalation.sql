-- Fix 3: don't auto-release payment the instant the 24h window passes.
-- Flag the order for admin review first; only actually release funds after
-- a longer grace period (or an admin manually approves it).
ALTER TABLE orders ADD COLUMN IF NOT EXISTS admin_review_flagged boolean DEFAULT false;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS admin_review_flagged_at timestamptz;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS extended_release_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_orders_admin_review_flagged ON orders(admin_review_flagged) WHERE admin_review_flagged = true;
