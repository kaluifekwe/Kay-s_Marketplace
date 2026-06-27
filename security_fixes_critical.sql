-- ============================================
-- DispatchPH — Critical/High security fixes
-- Run this in Supabase SQL Editor AFTER all previous migrations.
-- Safe to re-run (idempotent).
-- ============================================

-- ------------------------------------------------------------
-- 1. transactions / vendor_bank_accounts: "Service role manages..."
--    policies used USING(true)/WITH CHECK(true) with no role
--    restriction, so ANY authenticated user (not just the service
--    role used by Edge Functions) could read/write every payment
--    transaction and every vendor's bank account.
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "Service role manages transactions" ON transactions;
CREATE POLICY "Service role manages transactions"
  ON transactions FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS "Service role manages bank accounts" ON vendor_bank_accounts;
CREATE POLICY "Service role manages bank accounts"
  ON vendor_bank_accounts FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Vendor's own UPDATE policy was missing WITH CHECK, so a vendor
-- could not be guaranteed to keep updating their *own* row only.
DROP POLICY IF EXISTS "Vendors update own bank account" ON vendor_bank_accounts;
CREATE POLICY "Vendors update own bank account"
  ON vendor_bank_accounts FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- ------------------------------------------------------------
-- 2. device_tokens: "Service role can read all tokens" used
--    USING(true) with no role restriction — any signed-in user
--    could read every other user's FCM push token.
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "Service role can read all tokens" ON device_tokens;
CREATE POLICY "Service role can read all tokens"
  ON device_tokens FOR SELECT
  TO service_role
  USING (true);

-- ------------------------------------------------------------
-- 3. credit_transactions: INSERT policy used WITH CHECK(true),
--    letting any signed-in user forge cashback/refund credit
--    rows for any buyer. Only the service role (Edge Functions)
--    should be able to insert; buyers only read their own rows.
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "Service insert credits" ON credit_transactions;
CREATE POLICY "Service role manages credit transactions"
  ON credit_transactions FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- buyer_bank_accounts UPDATE policy was also missing WITH CHECK.
DROP POLICY IF EXISTS "Buyers update own bank" ON buyer_bank_accounts;
CREATE POLICY "Buyers update own bank"
  ON buyer_bank_accounts FOR UPDATE
  USING (buyer_id = auth.uid())
  WITH CHECK (buyer_id = auth.uid());

-- ------------------------------------------------------------
-- 4. product_variants: write policy only checked
--    auth.role() = 'authenticated', so ANY logged-in buyer could
--    edit or delete any vendor's variants. Scope to the vendor
--    that actually owns the product (via stores.vendor_id).
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "Authenticated can manage variants" ON product_variants;
CREATE POLICY "Vendors manage own product variants"
  ON product_variants FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM products p
      JOIN stores s ON s.id = p.store_id
      WHERE p.id = product_variants.product_id
        AND s.vendor_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM products p
      JOIN stores s ON s.id = p.store_id
      WHERE p.id = product_variants.product_id
        AND s.vendor_id = auth.uid()
    )
  );

-- ------------------------------------------------------------
-- 5. disputes.buyer_id / vendor_id: dispute_bloc.dart and the
--    evidence-system RLS policies both reference these columns,
--    and performance_indexes.sql indexes them, but no committed
--    migration ever creates them — confirmed schema drift.
--    Backfill from the parent order so existing rows are correct.
-- ------------------------------------------------------------
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS buyer_id uuid REFERENCES users(id);
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS vendor_id uuid REFERENCES users(id);

UPDATE disputes d
SET buyer_id = o.buyer_id,
    vendor_id = o.vendor_id
FROM orders o
WHERE d.order_id = o.id
  AND (d.buyer_id IS NULL OR d.vendor_id IS NULL);

CREATE INDEX IF NOT EXISTS idx_disputes_buyer_id ON disputes(buyer_id);
CREATE INDEX IF NOT EXISTS idx_disputes_vendor_id ON disputes(vendor_id);

-- ------------------------------------------------------------
-- 6. user_unique_id: was generated as a 4-digit value (only
--    10,000 possible combinations) — far too small for a
--    30,000-user target and guaranteed to start colliding well
--    before then. Widen to 6 digits (1,000,000 combinations) for
--    any user who doesn't yet have an ID. Existing 4-digit IDs
--    are left as-is (they are still unique) to avoid invalidating
--    IDs users may already be sharing/using.
-- ------------------------------------------------------------
DO $$
DECLARE
  rec RECORD;
  new_id text;
  id_exists boolean;
BEGIN
  FOR rec IN SELECT id FROM users WHERE unique_id IS NULL LOOP
    LOOP
      new_id := lpad(floor(random() * 1000000)::text, 6, '0');
      SELECT EXISTS(SELECT 1 FROM users WHERE unique_id = new_id) INTO id_exists;
      EXIT WHEN NOT id_exists;
    END LOOP;
    UPDATE users SET unique_id = new_id WHERE id = rec.id;
  END LOOP;
END $$;

-- ------------------------------------------------------------
-- 7. CreditService.useCredit() did a client-side read-check-write
--    on users.kays_credit (read balance, check, then update) with
--    no atomicity — two concurrent spends (e.g. double-tapping
--    "pay with credit", or two devices) could both pass the check
--    and overdraw the balance. Move the check-and-deduct into a
--    single atomic statement via RPC, matching the existing
--    increment_kays_credit / increment_user_refunds RPC pattern.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION spend_kays_credit(p_user_id uuid, p_amount numeric)
RETURNS numeric AS $$
  UPDATE users
  SET kays_credit = kays_credit - p_amount
  WHERE id = p_user_id
    AND kays_credit >= p_amount
  RETURNING kays_credit;
$$ LANGUAGE sql;

-- ------------------------------------------------------------
-- 8. ReviewCubit.loadStoreReviews() now caps the fetched list to
--    the most recent 50 reviews (avoiding an unbounded fetch of a
--    store's entire review history). This aggregate keeps the
--    average rating / review count accurate for stores with more
--    reviews than that.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_store_review_stats(p_store_id uuid)
RETURNS TABLE(avg_rating numeric, review_count bigint) AS $$
  SELECT COALESCE(AVG(rating), 0), COUNT(*)
  FROM reviews
  WHERE store_id = p_store_id;
$$ LANGUAGE sql STABLE;

-- ------------------------------------------------------------
-- 9. disputes.resolution_type: evidence_system_schema.sql adds a
--    CHECK constraint on this column, but no migration ever
--    creates the column itself — that ALTER TABLE ADD CONSTRAINT
--    would fail outright (column does not exist), aborting the
--    rest of that script. dispute_bloc.dart and process-refund
--    both already read/write disputes.resolution_type, so the
--    column must exist in the live DB by some untracked manual
--    change — add it here idempotently so this is reproducible.
-- ------------------------------------------------------------
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS resolution_type text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'valid_resolution_type'
  ) THEN
    ALTER TABLE disputes ADD CONSTRAINT valid_resolution_type
      CHECK (resolution_type IN ('refund', 'replacement', 'partial_refund', 'rejected', 'escalated'));
  END IF;
END $$;
