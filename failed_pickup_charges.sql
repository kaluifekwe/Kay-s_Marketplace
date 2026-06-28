-- Failed-pickup accountability: when a courier is dispatched but the vendor has
-- no package ready (delivery goes 'failed' before pickup), the platform ate the
-- courier fee. Record it as a pending charge against that vendor; release-escrow
-- nets pending charges off the vendor's next payout. Safe to run multiple times.

CREATE TABLE IF NOT EXISTS vendor_charges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID REFERENCES users(id) NOT NULL,
  order_id UUID REFERENCES orders(id),
  amount DECIMAL NOT NULL,
  reason TEXT NOT NULL,                 -- 'failed_pickup'
  status TEXT NOT NULL DEFAULT 'pending', -- pending | settled
  created_at TIMESTAMPTZ DEFAULT NOW(),
  settled_at TIMESTAMPTZ
);

-- One charge per order+reason — keeps webhook retries from double-charging.
CREATE UNIQUE INDEX IF NOT EXISTS uniq_vendor_charge_order_reason
  ON vendor_charges(order_id, reason);

CREATE INDEX IF NOT EXISTS idx_vendor_charges_pending
  ON vendor_charges(vendor_id) WHERE status = 'pending';

ALTER TABLE vendor_charges ENABLE ROW LEVEL SECURITY;

-- Vendors can read their own charges (writes are service-role only).
DROP POLICY IF EXISTS vendor_charges_owner_read ON vendor_charges;
CREATE POLICY vendor_charges_owner_read ON vendor_charges
  FOR SELECT USING (auth.uid() = vendor_id);
