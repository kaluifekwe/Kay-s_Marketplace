-- Security hardening v2 — CORRECTED to be non-breaking.
--
-- RLS controls rows, not columns. These BEFORE UPDATE triggers reject client
-- writes to columns that NO legitimate client flow ever updates (verified
-- against the app), so a user can't escalate privileges, unfreeze a held
-- payout, tamper order money fields, or bypass the intrastate state lock.
-- Service role (Edge Functions) and admins bypass. Safe to re-run.
--
-- NOTE: kays_credit and the dispute-tracking fields are intentionally NOT
-- guarded here because the app writes them client-side today (welcome credit,
-- credit checkout, dispute creation). Locking those requires moving those
-- writes server-side first — tracked as a follow-up (see checklist §6).

-- ── users: role escalation + payout self-unblock + state lock ──────────────
CREATE OR REPLACE FUNCTION guard_user_columns()
RETURNS trigger AS $$
BEGIN
  IF auth.role() = 'service_role'
     OR EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  THEN
    RETURN NEW;
  END IF;

  IF NEW.role                  IS DISTINCT FROM OLD.role
     OR NEW.payout_blocked        IS DISTINCT FROM OLD.payout_blocked
     OR NEW.payout_blocked_amount IS DISTINCT FROM OLD.payout_blocked_amount
     OR NEW.payout_blocked_reason IS DISTINCT FROM OLD.payout_blocked_reason
  THEN
    RAISE EXCEPTION 'Not allowed to modify protected user fields';
  END IF;

  -- Intrastate state lock: set once (NULL -> value), never changed afterwards
  -- except via the admin-approved state-change flow.
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

-- ── orders: money/release fields are Edge-Function-only ────────────────────
CREATE OR REPLACE FUNCTION guard_order_columns()
RETURNS trigger AS $$
BEGIN
  IF auth.role() = 'service_role'
     OR EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  THEN
    RETURN NEW;
  END IF;

  IF NEW.payment_released    IS DISTINCT FROM OLD.payment_released
     OR NEW.payout_status       IS DISTINCT FROM OLD.payout_status
     OR NEW.payout_attempts     IS DISTINCT FROM OLD.payout_attempts
     OR NEW.total               IS DISTINCT FROM OLD.total
     OR NEW.paid_at             IS DISTINCT FROM OLD.paid_at
     OR NEW.refunded_at         IS DISTINCT FROM OLD.refunded_at
     OR NEW.paystack_reference  IS DISTINCT FROM OLD.paystack_reference
     OR NEW.payment_reference   IS DISTINCT FROM OLD.payment_reference
  THEN
    RAISE EXCEPTION 'Not allowed to modify protected order fields';
  END IF;

  -- Only the buyer (confirming/raising) or service/admin may change has_dispute
  -- — a vendor must not clear it to unfreeze their payout.
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
