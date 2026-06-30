-- Lock the dispute anti-gaming fields on users. A buyer could directly PATCH
-- their own active_dispute_id (→ open multiple concurrent disputes),
-- dispute_flagged (→ un-flag themselves), dispute_strikes_count, or
-- last_dispute_at/last_dispute_vendor_id (→ bypass the 30-day per-vendor
-- cooldown). These are now guarded; the only legitimate client write (claiming
-- an active dispute at creation) goes through a SECURITY DEFINER RPC. Admin
-- resolution writes bypass via the admin check. Safe to re-run.
--
-- Reuses the existing 'app.allow_credit' transaction-local flag as the generic
-- "DEFINER function may write guarded user columns" bypass.

-- Buyer claims an active dispute (createDispute) — acts only on the caller.
CREATE OR REPLACE FUNCTION claim_active_dispute(p_dispute_id uuid, p_vendor_id uuid)
RETURNS void AS $$
BEGIN
  PERFORM set_config('app.allow_credit', '1', true);
  UPDATE users
     SET active_dispute_id      = p_dispute_id,
         last_dispute_at         = now(),
         last_dispute_vendor_id  = p_vendor_id
   WHERE id = auth.uid();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION claim_active_dispute(uuid, uuid) TO authenticated, service_role;

-- Expanded users guard: role, credit, payout-block, dispute anti-gaming, state.
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
  THEN
    RAISE EXCEPTION 'Not allowed to modify protected user fields';
  END IF;

  IF OLD.state IS NOT NULL AND NEW.state IS DISTINCT FROM OLD.state THEN
    RAISE EXCEPTION 'State is locked — use the state-change request flow';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
