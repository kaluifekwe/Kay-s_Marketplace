-- Fix cart +/- quantity buttons. cart_items had INSERT/SELECT/DELETE policies
-- but NO UPDATE policy, so with RLS on, changing quantity was silently denied
-- (0 rows affected) and the plus/minus buttons appeared to do nothing.
-- Safe to re-run.

DROP POLICY IF EXISTS "Cart owner update" ON cart_items;
CREATE POLICY "Cart owner update" ON cart_items
  FOR UPDATE
  USING (auth.uid() = buyer_id)
  WITH CHECK (auth.uid() = buyer_id);

NOTIFY pgrst, 'reload schema';
