-- H1 + H2 + M2 — dispute payout hold moved server-side, made atomic, plus a
-- real vendor clawback for post-release refunds. Run in the Supabase SQL editor.
-- Safe to re-run.
--
-- WHY (audit findings):
--  H1  The hold that reserves a vendor's money to fund a possible buyer-favour
--      refund was written CLIENT-SIDE (dispute_bloc.dart) to users.payout_blocked
--      — a column blocked by guard_user_columns. The write silently failed, so
--      the hold NEVER applied: a vendor with an unresolved post-payment dispute
--      still got every other escrow released and could withdraw it.
--  H2  When a dispute refund is paid AFTER the vendor was already paid out, the
--      platform absorbed it with no clawback. Now we pull it back from the
--      vendor's wallet (up to balance) and book any shortfall as a pending
--      vendor_charge (netted off their next payout by release-escrow).
--  M2  payout_blocked_amount was mutated read-then-write in several places, so
--      concurrent disputes/resolutions could lose updates. All mutation is now a
--      single atomic UPDATE inside these DEFINER RPCs.
--
-- These reuse the existing 'app.allow_credit' transaction-local flag as the
-- "DEFINER function may write guarded user columns" bypass, exactly like
-- claim_active_dispute in secure_disputes.sql.

-- Idempotent release claim — so a refund path and a manual release can't both
-- decrement the same hold.
ALTER TABLE public.disputes
  ADD COLUMN IF NOT EXISTS payout_hold_released boolean NOT NULL DEFAULT false;

-- ── H1 + M2: apply the hold when a POST-PAYMENT dispute is opened ───────────
-- Callable by the order's buyer (raising the dispute), an admin, or the service
-- role. Idempotent: claims the dispute as post-payment ONCE (is_post_payment
-- false -> true) so a retry can't double-count. Increments the vendor's blocked
-- amount ATOMICALLY.
CREATE OR REPLACE FUNCTION apply_dispute_payout_hold(p_dispute_id uuid, p_order_id uuid)
RETURNS jsonb AS $$
DECLARE
  v_buyer    uuid;
  v_vendor   uuid;
  v_released boolean;
  v_owed     numeric;
  v_claimed  uuid;
BEGIN
  SELECT buyer_id, vendor_id, payment_released, COALESCE(total_with_delivery, total, 0)
    INTO v_buyer, v_vendor, v_released, v_owed
    FROM orders WHERE id = p_order_id;
  IF v_buyer IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;

  IF auth.role() <> 'service_role'
     AND auth.uid() <> v_buyer
     AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin') THEN
    RAISE EXCEPTION 'Not authorized to hold payout for this order';
  END IF;

  -- Only relevant once the vendor has already been paid; otherwise the escrow
  -- itself is still held (has_dispute blocks release-escrow).
  IF v_released IS NOT TRUE THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'not_released');
  END IF;

  UPDATE disputes
     SET is_post_payment = true, vendor_owes_refund = v_owed
   WHERE id = p_dispute_id
     AND order_id = p_order_id
     AND COALESCE(is_post_payment, false) = false
   RETURNING id INTO v_claimed;
  IF v_claimed IS NULL THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'already_applied');
  END IF;

  PERFORM set_config('app.allow_credit', '1', true);
  UPDATE users
     SET payout_blocked_amount = GREATEST(0, COALESCE(payout_blocked_amount, 0) + v_owed),
         payout_blocked        = true,
         payout_blocked_reason = 'Active dispute on order ' || p_order_id::text
   WHERE id = v_vendor;

  RETURN jsonb_build_object('applied', true, 'owed', v_owed, 'vendor_id', v_vendor);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION apply_dispute_payout_hold(uuid, uuid) TO authenticated, service_role;

-- ── M2: release the hold when the dispute concludes ─────────────────────────
-- Admin or service role only — a vendor must NOT be able to self-release their
-- own hold mid-dispute. Idempotent: claims payout_hold_released ONCE, then
-- decrements the vendor's blocked amount ATOMICALLY and clears the flag at zero.
CREATE OR REPLACE FUNCTION release_dispute_payout_hold(p_dispute_id uuid)
RETURNS jsonb AS $$
DECLARE
  v_vendor uuid;
  v_owed   numeric;
  v_amt    numeric;
BEGIN
  IF auth.role() <> 'service_role'
     AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin') THEN
    RAISE EXCEPTION 'Not authorized to release payout hold';
  END IF;

  UPDATE disputes
     SET payout_hold_released = true
   WHERE id = p_dispute_id
     AND is_post_payment = true
     AND COALESCE(payout_hold_released, false) = false
   RETURNING vendor_id, COALESCE(vendor_owes_refund, 0) INTO v_vendor, v_owed;
  IF v_vendor IS NULL THEN
    RETURN jsonb_build_object('released', false, 'reason', 'nothing_to_release');
  END IF;

  PERFORM set_config('app.allow_credit', '1', true);
  UPDATE users
     SET payout_blocked_amount = GREATEST(0, COALESCE(payout_blocked_amount, 0) - v_owed)
   WHERE id = v_vendor
   RETURNING payout_blocked_amount INTO v_amt;

  UPDATE users
     SET payout_blocked        = (COALESCE(v_amt, 0) > 0),
         payout_blocked_reason = CASE WHEN COALESCE(v_amt, 0) > 0 THEN payout_blocked_reason ELSE NULL END
   WHERE id = v_vendor;

  RETURN jsonb_build_object('released', true, 'remaining', COALESCE(v_amt, 0));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION release_dispute_payout_hold(uuid) TO authenticated, service_role;

-- ── H2: recover a post-release refund from the vendor ───────────────────────
-- Service-role only, atomic, idempotent on p_reference. Debits the vendor's
-- wallet up to their balance and books any shortfall as a pending vendor_charge
-- (recovered from their next payout by release-escrow's charge netting).
CREATE OR REPLACE FUNCTION wallet_clawback(
  p_vendor_id uuid,
  p_amount    numeric,
  p_reference text,
  p_order_id  uuid DEFAULT NULL,
  p_reason    text DEFAULT 'dispute_refund_shortfall'
) RETURNS jsonb AS $$
DECLARE
  v_balance numeric;
  v_debit   numeric;
  v_short   numeric;
  v_tx_id   uuid;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'wallet_clawback is service-role only';
  END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Invalid amount'; END IF;
  IF p_reference IS NULL THEN RAISE EXCEPTION 'reference is required for idempotency'; END IF;

  -- Lock the wallet so the balance we read is the balance we debit.
  SELECT balance INTO v_balance FROM wallets WHERE user_id = p_vendor_id FOR UPDATE;
  v_balance := COALESCE(v_balance, 0);
  v_debit := LEAST(v_balance, p_amount);
  v_short := p_amount - v_debit;

  -- Idempotency gate: one clawback per reference.
  INSERT INTO wallet_transactions (user_id, amount, balance_after, type, status, reference, order_id, description)
  VALUES (p_vendor_id, -v_debit, v_balance - v_debit, 'clawback', 'success', p_reference, p_order_id, 'Dispute refund clawback')
  ON CONFLICT (reference) DO NOTHING
  RETURNING id INTO v_tx_id;
  IF v_tx_id IS NULL THEN
    RETURN jsonb_build_object('status', 'replay');
  END IF;

  IF v_debit > 0 THEN
    PERFORM set_config('app.allow_wallet', '1', true);
    UPDATE wallets SET balance = balance - v_debit WHERE user_id = p_vendor_id;
  END IF;

  IF v_short > 0 THEN
    INSERT INTO vendor_charges (vendor_id, order_id, amount, reason, status)
    VALUES (p_vendor_id, p_order_id, v_short, p_reason, 'pending')
    ON CONFLICT (order_id, reason) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('status', 'ok', 'debited', v_debit, 'shortfall', v_short);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION wallet_clawback(uuid, numeric, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION wallet_clawback(uuid, numeric, text, uuid, text) TO service_role;

NOTIFY pgrst, 'reload schema';
