-- DispatchPH Evidence-Based Trust System
-- Run this in Supabase SQL Editor

-- ============================================
-- 1. ADD DELIVERY FIELDS TO ORDERS TABLE
-- ============================================
ALTER TABLE orders ADD COLUMN IF NOT EXISTS rider_name text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS rider_phone text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS delivery_method text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS shipping_proof_url text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS delivery_photo_url text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS delivery_confirmed_at timestamptz;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS auto_release_at timestamptz;

-- ============================================
-- 2. ADD EVIDENCE FIELDS TO DISPUTES TABLE
-- ============================================
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS issue_type text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS evidence_urls text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS vendor_evidence_urls text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS buyer_phone text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS delivery_address text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS resolution_deadline timestamptz;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS escalated_to_admin boolean DEFAULT false;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS buyer_explanation text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS buyer_submitted_at timestamptz;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS vendor_responded_at timestamptz;

-- ============================================
-- 3. ADD TRUST FIELDS TO USERS TABLE
-- ============================================
ALTER TABLE users ADD COLUMN IF NOT EXISTS trust_score integer DEFAULT 100;
ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_verified boolean DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS total_refunds integer DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS total_purchases integer DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS total_on_time_confirmations integer DEFAULT 0;

-- ============================================
-- 4. CREATE INDEXES FOR NEW FIELDS
-- ============================================
CREATE INDEX IF NOT EXISTS idx_orders_auto_release ON orders(auto_release_at);
CREATE INDEX IF NOT EXISTS idx_disputes_deadline ON disputes(resolution_deadline);
CREATE INDEX IF NOT EXISTS idx_disputes_escalated ON disputes(escalated_to_admin);
CREATE INDEX IF NOT EXISTS idx_users_trust ON users(trust_score);

-- ============================================
-- 5. UPDATE EXISTING DISPUTES TO HAVE DEFAULT DEADLINE
-- ============================================
UPDATE disputes 
SET resolution_deadline = created_at + interval '48 hours'
WHERE resolution_deadline IS NULL;

-- ============================================
-- 6. UPDATE EXISTING ORDERS TO HAVE DEFAULT TIMERS
-- ============================================
UPDATE orders 
SET auto_release_at = created_at + interval '24 hours'
WHERE auto_release_at IS NULL AND status IN ('paid', 'shipped', 'delivered');

-- ============================================
-- 7. CREATE FUNCTION TO AUTO-RELEASE PAYMENTS
-- ============================================
CREATE OR REPLACE FUNCTION auto_release_payments()
RETURNS void AS $$
BEGIN
  UPDATE orders 
  SET status = 'completed', 
      updated_at = now()
  WHERE status = 'delivered' 
    AND auto_release_at IS NOT NULL 
    AND auto_release_at < now()
    AND payment_released = false;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 8. CREATE FUNCTION TO ESCALATE OLD DISPUTES
-- ============================================
CREATE OR REPLACE FUNCTION escalate_old_disputes()
RETURNS void AS $$
BEGIN
  UPDATE disputes 
  SET escalated_to_admin = true,
      status = 'escalated'
  WHERE status NOT IN ('resolved', 'cancelled')
    AND resolution_deadline IS NOT NULL 
    AND resolution_deadline < now()
    AND escalated_to_admin = false;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 9. CREATE SCHEDULED FUNCTION (run every hour)
-- ============================================
-- Note: Supabase doesn't support pg_cron directly
-- These functions will be called from the app or a cron job

-- ============================================
-- 10. ADD PAYMENT RELEASED FIELD TO ORDERS
-- ============================================
ALTER TABLE orders ADD COLUMN IF NOT EXISTS payment_released boolean DEFAULT false;

-- ============================================
-- 11. UPDATE ORDERS TABLE FOR BETTER TRACKING
-- ============================================
ALTER TABLE orders ADD COLUMN IF NOT EXISTS shipping_photo_at timestamptz;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS shipped_at timestamptz;

-- ============================================
-- 12. CREATE DISPUTE RESOLUTION LOG TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS dispute_actions (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  dispute_id uuid REFERENCES disputes(id) ON DELETE CASCADE,
  action_type text NOT NULL, -- 'evidence_uploaded', 'response_submitted', 'replacement_offered', 'resolved', 'escalated'
  actor_id uuid REFERENCES users(id),
  actor_role text NOT NULL, -- 'buyer', 'vendor', 'admin'
  details jsonb,
  created_at timestamptz DEFAULT now()
);

-- Enable RLS for dispute_actions
ALTER TABLE dispute_actions ENABLE ROW LEVEL SECURITY;

-- Policies for dispute_actions
CREATE POLICY "Dispute actions visible to dispute participants"
  ON dispute_actions FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM disputes d
      WHERE d.id = dispute_actions.dispute_id
      AND (d.buyer_id = auth.uid() OR d.vendor_id = auth.uid())
    )
  );

CREATE POLICY "Dispute actions can be created by participants"
  ON dispute_actions FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM disputes d
      WHERE d.id = dispute_actions.dispute_id
      AND (d.buyer_id = auth.uid() OR d.vendor_id = auth.uid())
    )
  );

-- ============================================
-- 13. ADD ISSUE TYPE CHECK CONSTRAINT
-- ============================================
ALTER TABLE disputes ADD CONSTRAINT valid_issue_type 
  CHECK (issue_type IN ('wrong_item', 'damaged', 'not_as_described', 'not_received', 'other'));

-- ============================================
-- 14. ADD RESOLUTION TYPE CHECK CONSTRAINT
-- ============================================
ALTER TABLE disputes ADD CONSTRAINT valid_resolution_type 
  CHECK (resolution_type IN ('refund', 'replacement', 'partial_refund', 'rejected', 'escalated'));

-- ============================================
-- 15. ADD DISPUTE STATUS VALUES
-- ============================================
ALTER TABLE disputes ADD CONSTRAINT valid_dispute_status 
  CHECK (status IN ('open', 'vendor_responded', 'evidence_submitted', 'replacement_offered', 
                     'replacement_accepted', 'resolved', 'rejected', 'escalated', 'cancelled'));

-- ============================================
-- 16. CREATE REVIEWS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS reviews (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  store_id uuid REFERENCES stores(id) ON DELETE CASCADE,
  user_id uuid REFERENCES users(id),
  order_id text,
  rating integer NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment text,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reviews_store ON reviews(store_id);
CREATE INDEX IF NOT EXISTS idx_reviews_user ON reviews(user_id);

ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read reviews"
  ON reviews FOR SELECT
  USING (true);

CREATE POLICY "Buyers can create reviews"
  ON reviews FOR INSERT
  WITH CHECK (auth.uid() = user_id);
