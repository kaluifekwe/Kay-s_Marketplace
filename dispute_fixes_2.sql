-- Fix 1: return deadline already uses real-time comparison server-side; only
-- the duration used to SET the deadline changes (7 days -> 24h), done in Dart.

-- Fix 2: drop courier/tracking fields, add return photo pair
ALTER TABLE disputes DROP COLUMN IF EXISTS return_courier_name;
ALTER TABLE disputes DROP COLUMN IF EXISTS return_tracking_number;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS return_receipt_photos text DEFAULT '[]';

-- Fix 3: vendor return-confirmation step
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS vendor_confirm_deadline timestamptz;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS vendor_return_confirmed_at timestamptz;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS vendor_return_received_photo text;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS vendor_confirm_last_reminder_at timestamptz;

ALTER TABLE users ADD COLUMN IF NOT EXISTS vendor_warnings_count int DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS vendor_flagged boolean DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS vendor_flagged_at timestamptz;

-- Fix 4: payout hold for post-payment disputes
ALTER TABLE users ADD COLUMN IF NOT EXISTS payout_blocked boolean DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS payout_blocked_reason text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS payout_blocked_amount numeric DEFAULT 0;

ALTER TABLE disputes ADD COLUMN IF NOT EXISTS is_post_payment boolean DEFAULT false;
ALTER TABLE disputes ADD COLUMN IF NOT EXISTS vendor_owes_refund numeric DEFAULT 0;

-- widen status check for the new vendor_confirming stage
ALTER TABLE disputes DROP CONSTRAINT IF EXISTS disputes_status_check;
ALTER TABLE disputes ADD CONSTRAINT disputes_status_check CHECK (status IN (
  'open','vendor_responded','evidence_submitted','replacement_offered','replacement_accepted',
  'resolved','rejected','escalated','cancelled',
  'awaiting_vendor_response','awaiting_admin_decision','awaiting_return','return_submitted',
  'return_verified','refunded','denied','auto_closed','vendor_confirming'
));
