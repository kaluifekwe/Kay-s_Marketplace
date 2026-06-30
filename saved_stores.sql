-- "My Stores": a buyer saves a vendor's store by its short numeric ID
-- (users.unique_id, shared by the vendor) for quick access. View/buy still
-- follow the usual rules (buying/chatting needs same-state + KYC). Safe to re-run.

CREATE TABLE IF NOT EXISTS saved_stores (
  buyer_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  store_id   UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (buyer_id, store_id)
);

CREATE INDEX IF NOT EXISTS idx_saved_stores_buyer ON saved_stores(buyer_id);

ALTER TABLE saved_stores ENABLE ROW LEVEL SECURITY;

-- A buyer manages only their own saved list.
DROP POLICY IF EXISTS saved_stores_owner_read ON saved_stores;
CREATE POLICY saved_stores_owner_read ON saved_stores
  FOR SELECT USING (buyer_id = auth.uid());

DROP POLICY IF EXISTS saved_stores_owner_insert ON saved_stores;
CREATE POLICY saved_stores_owner_insert ON saved_stores
  FOR INSERT WITH CHECK (buyer_id = auth.uid());

DROP POLICY IF EXISTS saved_stores_owner_delete ON saved_stores;
CREATE POLICY saved_stores_owner_delete ON saved_stores
  FOR DELETE USING (buyer_id = auth.uid());
