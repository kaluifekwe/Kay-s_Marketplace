-- Close the withdrawal TOCTOU: make the "how much may this user withdraw" check
-- and the debit ONE atomic, row-locked operation. Previously wallet-withdraw
-- called wallet_withdrawable (read) then wallet_debit (write) as two steps, so
-- two concurrent withdrawals could each pass the cap check before either debit
-- landed — letting a buyer withdraw more than their REFUNDED amount (the raw
-- balance was always safe; only the refunds-only business rule could be raced).
--
-- wallet_withdraw_debit locks the wallet row FOR UPDATE first, so concurrent
-- withdrawals for the same user serialize: the second call recomputes the cap
-- only after the first has committed its withdrawal, and is rejected if it now
-- exceeds. Service-role only, idempotent on `reference`. Safe to re-run.

CREATE OR REPLACE FUNCTION wallet_withdraw_debit(
  p_user_id       uuid,
  p_amount        numeric,
  p_reference     text,
  p_withdrawal_id uuid
) RETURNS jsonb AS $$
DECLARE
  v_role      text;
  v_balance   numeric;
  v_refunds   numeric;
  v_withdrawn numeric;
  v_cap       numeric;
  v_tx_id     uuid;
  v_new_bal   numeric;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'wallet_withdraw_debit is service-role only';
  END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Invalid amount'; END IF;
  IF p_reference IS NULL THEN RAISE EXCEPTION 'reference is required for idempotency'; END IF;

  -- Lock the wallet row FIRST — serializes concurrent withdrawals for this user
  -- so the cap check below cannot be raced.
  SELECT balance INTO v_balance FROM wallets WHERE user_id = p_user_id FOR UPDATE;
  IF v_balance IS NULL THEN
    RETURN jsonb_build_object('status', 'no_wallet', 'balance', 0);
  END IF;

  -- Idempotency: reserve the reference. A replay returns the (locked) balance.
  INSERT INTO wallet_transactions (user_id, amount, balance_after, type, status,
    reference, withdrawal_id, description)
  VALUES (p_user_id, -p_amount, 0, 'withdrawal', 'success',
    p_reference, p_withdrawal_id, 'Withdrawal to bank')
  ON CONFLICT (reference) DO NOTHING
  RETURNING id INTO v_tx_id;

  IF v_tx_id IS NULL THEN
    RETURN jsonb_build_object('status', 'replay', 'balance', v_balance);
  END IF;

  -- Withdrawable cap: vendors = full balance; buyers = refunded money only,
  -- capped at the balance. Exclude our own just-reserved row from the tally.
  SELECT role INTO v_role FROM users WHERE id = p_user_id;
  IF v_role = 'vendor' THEN
    v_cap := v_balance;
  ELSE
    SELECT COALESCE(SUM(amount), 0) INTO v_refunds
      FROM wallet_transactions
      WHERE user_id = p_user_id AND type = 'refund' AND status = 'success';
    SELECT COALESCE(SUM(-amount), 0) INTO v_withdrawn
      FROM wallet_transactions
      WHERE user_id = p_user_id AND type = 'withdrawal'
        AND status IN ('success', 'pending') AND id <> v_tx_id;
    v_cap := GREATEST(LEAST(v_balance, v_refunds - v_withdrawn), 0);
  END IF;

  IF p_amount > v_cap THEN
    DELETE FROM wallet_transactions WHERE id = v_tx_id; -- free the reference to retry
    RETURN jsonb_build_object('status', 'exceeds_withdrawable', 'withdrawable', v_cap);
  END IF;

  -- Atomic debit (belt-and-braces overdraw guard, inside the lock).
  PERFORM set_config('app.allow_wallet', '1', true);
  UPDATE wallets SET balance = balance - p_amount
    WHERE user_id = p_user_id AND balance >= p_amount
    RETURNING balance INTO v_new_bal;

  IF v_new_bal IS NULL THEN
    DELETE FROM wallet_transactions WHERE id = v_tx_id;
    RETURN jsonb_build_object('status', 'insufficient', 'balance', v_balance);
  END IF;

  UPDATE wallet_transactions SET balance_after = v_new_bal WHERE id = v_tx_id;
  RETURN jsonb_build_object('status', 'ok', 'balance', v_new_bal);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION wallet_withdraw_debit(uuid, numeric, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION wallet_withdraw_debit(uuid, numeric, text, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
