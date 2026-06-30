-- Close the kays_credit minting hole.
--
-- Before: increment_kays_credit was callable by any client (the ₦200 welcome
-- credit was granted client-side at registration), so an attacker could call
-- increment_kays_credit(self, 1e9) — or directly PATCH users.kays_credit — to
-- mint unlimited credit. Now:
--   * kays_credit is a guarded column (only changeable via the DEFINER credit
--     functions, which set a transaction-local bypass flag).
--   * increment_kays_credit is service-role only (Edge Functions: cashback,
--     refunds). Welcome credit is granted server-side by a trigger.
--   * spend_kays_credit only ever deducts, and only the owner (or service role)
--     may call it.
-- Safe to re-run.

-- ── add credit: service-role only ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION increment_kays_credit(p_user_id uuid, p_amount numeric)
RETURNS numeric AS $$
DECLARE result numeric;
BEGIN
  PERFORM set_config('app.allow_credit', '1', true);
  UPDATE users SET kays_credit = COALESCE(kays_credit, 0) + p_amount
   WHERE id = p_user_id
   RETURNING kays_credit INTO result;
  RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION increment_kays_credit(uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION increment_kays_credit(uuid, numeric) TO service_role;

-- ── spend credit: owner-or-service, deduct-only, atomic ────────────────────
CREATE OR REPLACE FUNCTION spend_kays_credit(p_user_id uuid, p_amount numeric)
RETURNS numeric AS $$
DECLARE result numeric;
BEGIN
  IF auth.role() <> 'service_role' AND p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Cannot spend another user''s credit';
  END IF;
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Invalid amount';
  END IF;
  PERFORM set_config('app.allow_credit', '1', true);
  UPDATE users SET kays_credit = kays_credit - p_amount
   WHERE id = p_user_id AND kays_credit >= p_amount
   RETURNING kays_credit INTO result;
  RETURN result; -- NULL when insufficient funds (no row updated)
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION spend_kays_credit(uuid, numeric) TO authenticated, service_role;

-- ── welcome credit: granted server-side at signup (not by the client) ──────
CREATE OR REPLACE FUNCTION grant_welcome_credit()
RETURNS trigger AS $$
BEGIN
  IF NEW.role = 'buyer' THEN
    PERFORM set_config('app.allow_credit', '1', true);
    UPDATE users SET kays_credit = COALESCE(kays_credit, 0) + 200 WHERE id = NEW.id;
    INSERT INTO credit_transactions (buyer_id, amount, type, description, expires_at)
      VALUES (NEW.id, 200, 'cashback', '₦200 welcome bonus', now() + interval '90 days');
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_grant_welcome_credit ON users;
CREATE TRIGGER trg_grant_welcome_credit
  AFTER INSERT ON users
  FOR EACH ROW EXECUTE FUNCTION grant_welcome_credit();

-- ── guard kays_credit (+ keep role / payout_blocked / state lock) ──────────
-- Replaces guard_user_columns: now also blocks direct client writes to
-- kays_credit, except when a DEFINER credit function set the bypass flag.
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
     OR NEW.kays_credit           IS DISTINCT FROM OLD.kays_credit
     OR NEW.payout_blocked        IS DISTINCT FROM OLD.payout_blocked
     OR NEW.payout_blocked_amount IS DISTINCT FROM OLD.payout_blocked_amount
     OR NEW.payout_blocked_reason IS DISTINCT FROM OLD.payout_blocked_reason
  THEN
    RAISE EXCEPTION 'Not allowed to modify protected user fields';
  END IF;

  IF OLD.state IS NOT NULL AND NEW.state IS DISTINCT FROM OLD.state THEN
    RAISE EXCEPTION 'State is locked — use the state-change request flow';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- (trigger trg_guard_user_columns from harden_rls.sql already points here.)
