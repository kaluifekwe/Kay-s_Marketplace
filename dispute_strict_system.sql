-- Strict dispute & refund system upgrade (built on existing disputes/orders/users tables)

-- orders: dispute window + pre-ship photos
ALTER TABLE orders ADD COLUMN IF NOT EXISTS dispute_deadline timestamptz;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS has_dispute boolean DEFAULT false;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS pre_ship_photos text DEFAULT '[]';

-- users: strike / flag tracking
ALTER TABLE users ADD COLUMN IF NOT EXISTS dispute_strikes_count int DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS dispute_flagged boolean DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS dispute_flagged_at timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS active_dispute_id uuid;
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_dispute_at timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_dispute_vendor_id uuid;

-- disputes: strict workflow fields (return/courier/admin-decision stage on top of existing columns)
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS vendor_response_deadline timestamptz;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS admin_decision text; -- 'refund_approved','refund_denied'
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS admin_decided_by uuid REFERENCES users(id);
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS admin_decided_at timestamptz;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS admin_notes text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS return_required boolean DEFAULT false;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS return_deadline timestamptz;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS return_courier_name text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS return_tracking_number text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS return_package_photo_url text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS return_receipt_photo_url text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS return_uploaded_at timestamptz;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS return_verified boolean DEFAULT false;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS return_verified_at timestamptz;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS refund_method text; -- 'credit','bank','card'
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS video_url text; -- required if order > 50000
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS auto_closed boolean DEFAULT false;

-- widen status check to include strict-flow states
ALTER TABLE disputes DROP CONSTRAINT IF EXISTS disputes_status_check;
ALTER TABLE disputes ADD CONSTRAINT disputes_status_check CHECK (status IN (
  'open','vendor_responded','evidence_submitted','replacement_offered','replacement_accepted',
  'resolved','rejected','escalated','cancelled',
  'awaiting_vendor_response','awaiting_admin_decision','awaiting_return','return_submitted','return_verified','refunded','denied','auto_closed'
));

-- 4 fixed reasons enforced at app layer + DB check
ALTER TABLE disputes DROP CONSTRAINT IF EXISTS disputes_issue_type_check;
ALTER TABLE disputes ADD CONSTRAINT disputes_issue_type_check CHECK (issue_type IN (
  'wrong_item','damaged','not_as_described','not_received'
));

-- RLS: admin can update disputes (decision), admin can select all
DROP POLICY IF EXISTS disputes_admin_select ON disputes;
CREATE POLICY disputes_admin_select ON disputes FOR SELECT USING (
  EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
);
DROP POLICY IF EXISTS disputes_admin_update ON disputes;
CREATE POLICY disputes_admin_update ON disputes FOR UPDATE USING (
  EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
);

CREATE INDEX IF NOT EXISTS idx_disputes_status ON disputes(status);
CREATE INDEX IF NOT EXISTS idx_orders_dispute_deadline ON orders(dispute_deadline);
