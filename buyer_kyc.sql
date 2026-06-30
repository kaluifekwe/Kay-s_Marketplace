-- Buyer KYC (NIN). A buyer must be verified before they can buy; browsing is
-- always allowed. kyc_status is set ONLY by the verify-nin Edge Function
-- (service role) — a buyer can't self-verify via a direct PATCH, so it's added
-- to the users column guard. `nin` already exists. Safe to re-run.

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS kyc_status TEXT NOT NULL DEFAULT 'none',  -- none | pending | verified | rejected
  ADD COLUMN IF NOT EXISTS kyc_verified_at TIMESTAMPTZ;

-- Re-assert the users column guard, now also protecting kyc_status /
-- kyc_verified_at / nin (only service role / admin may set them).
CREATE OR REPLACE FUNCTION guard_user_columns()
RETURNS trigger AS $$
BEGIN
  IF auth.role() = 'service_role'
     OR current_setting('app.allow_credit', true) = '1'
     OR EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  THEN
    RETURN NEW;
  END IF;

  IF NEW.role                  IS DISTINCT FROM OLD.role
     OR NEW.kays_credit            IS DISTINCT FROM OLD.kays_credit
     OR NEW.payout_blocked         IS DISTINCT FROM OLD.payout_blocked
     OR NEW.payout_blocked_amount  IS DISTINCT FROM OLD.payout_blocked_amount
     OR NEW.payout_blocked_reason  IS DISTINCT FROM OLD.payout_blocked_reason
     OR NEW.active_dispute_id      IS DISTINCT FROM OLD.active_dispute_id
     OR NEW.last_dispute_at        IS DISTINCT FROM OLD.last_dispute_at
     OR NEW.last_dispute_vendor_id IS DISTINCT FROM OLD.last_dispute_vendor_id
     OR NEW.dispute_flagged        IS DISTINCT FROM OLD.dispute_flagged
     OR NEW.dispute_flagged_at     IS DISTINCT FROM OLD.dispute_flagged_at
     OR NEW.dispute_strikes_count  IS DISTINCT FROM OLD.dispute_strikes_count
     OR NEW.kyc_status             IS DISTINCT FROM OLD.kyc_status
     OR NEW.kyc_verified_at        IS DISTINCT FROM OLD.kyc_verified_at
     OR NEW.nin                    IS DISTINCT FROM OLD.nin
  THEN
    RAISE EXCEPTION 'Not allowed to modify protected user fields';
  END IF;

  IF OLD.state IS NOT NULL AND NEW.state IS DISTINCT FROM OLD.state THEN
    RAISE EXCEPTION 'State is locked — use the state-change request flow';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
