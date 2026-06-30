-- Security hardening: protect privileged columns from client writes.
--
-- RLS controls WHICH ROWS a user can touch, not WHICH COLUMNS. The
-- "Users update own" / "Orders * update" policies let a user update their own
-- row freely — so a user could set role='admin', mint kays_credit, clear their
-- dispute flags, bypass the intrastate state lock, or (as a vendor) clear an
-- order's has_dispute / tamper money fields to force a payout. These BEFORE
-- UPDATE triggers reject changes to sensitive columns unless the caller is the
-- service role (Edge Functions) or an admin. Safe to run multiple times.

-- ── users ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION guard_user_columns()
RETURNS trigger AS $$
BEGIN
  -- Edge Functions (service role) and admins may change anything.
  IF auth.role() = 'service_role'
     OR EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  THEN
    RETURN NEW;
  END IF;

  IF NEW.role               IS DISTINCT FROM OLD.role
     OR NEW.kays_credit         IS DISTINCT FROM OLD.kays_credit
     OR NEW.dispute_flagged     IS DISTINCT FROM OLD.dispute_flagged
     OR NEW.dispute_strikes_count IS DISTINCT FROM OLD.dispute_strikes_count
     OR NEW.active_dispute_id   IS DISTINCT FROM OLD.active_dispute_id
     OR NEW.last_dispute_at     IS DISTINCT FROM OLD.last_dispute_at
     OR NEW.last_dispute_vendor_id IS DISTINCT FROM OLD.last_dispute_vendor_id
     OR NEW.payout_blocked      IS DISTINCT FROM OLD.payout_blocked
     OR NEW.payout_blocked_amount IS DISTINCT FROM OLD.payout_blocked_amount
     OR NEW.payout_blocked_reason IS DISTINCT FROM OLD.payout_blocked_reason
  THEN
    RAISE EXCEPTION 'Not allowed to modify protected user fields';
  END IF;

  -- Intrastate state lock: state may be set once (NULL -> value) but never
  -- changed afterward except via the admin-approved state-change flow.
  IF OLD.state IS NOT NULL AND NEW.state IS DISTINCT FROM OLD.state THEN
    RAISE EXCEPTION 'State is locked — use the state-change request flow';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_guard_user_columns ON users;
CREATE TRIGGER trg_guard_user_columns
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION guard_user_columns();

-- ── orders ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION guard_order_columns()
RETURNS trigger AS $$
BEGIN
  IF auth.role() = 'service_role'
     OR EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  THEN
    RETURN NEW;
  END IF;

  -- Money / release-control columns are set only by Edge Functions.
  IF NEW.payment_released   IS DISTINCT FROM OLD.payment_released
     OR NEW.payout_status      IS DISTINCT FROM OLD.payout_status
     OR NEW.payout_attempts    IS DISTINCT FROM OLD.payout_attempts
     OR NEW.total              IS DISTINCT FROM OLD.total
     OR NEW.total_with_delivery IS DISTINCT FROM OLD.total_with_delivery
     OR NEW.delivery_fee       IS DISTINCT FROM OLD.delivery_fee
     OR NEW.vendor_delivery_contribution IS DISTINCT FROM OLD.vendor_delivery_contribution
     OR NEW.refunded_at        IS DISTINCT FROM OLD.refunded_at
     OR NEW.paid_at            IS DISTINCT FROM OLD.paid_at
     OR NEW.admin_review_flagged IS DISTINCT FROM OLD.admin_review_flagged
     OR NEW.extended_release_at IS DISTINCT FROM OLD.extended_release_at
     OR NEW.paystack_reference IS DISTINCT FROM OLD.paystack_reference
     OR NEW.payment_reference  IS DISTINCT FROM OLD.payment_reference
  THEN
    RAISE EXCEPTION 'Not allowed to modify protected order fields';
  END IF;

  -- Only the buyer (confirming) or service role may clear/raise has_dispute —
  -- a vendor must not be able to clear a dispute to unfreeze their payout.
  IF NEW.has_dispute IS DISTINCT FROM OLD.has_dispute
     AND auth.uid() IS DISTINCT FROM OLD.buyer_id
  THEN
    RAISE EXCEPTION 'Not allowed to modify dispute state';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_guard_order_columns ON orders;
CREATE TRIGGER trg_guard_order_columns
  BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION guard_order_columns();
