-- ============================================================================
-- WALLET SYSTEM — buyer + vendor wallets, ledger, withdrawals
-- Run in Supabase SQL Editor. Safe to re-run.
--
-- Money model (see plan): buyers fund a wallet (Flutterwave virtual account),
-- pay for orders from it (-> escrow), vendors receive sale proceeds into their
-- wallet and withdraw to bank. A single wallet row per user (a user can be both
-- buyer and vendor). `balance` = spendable; escrow-held funds have already left
-- the wallet and are tracked per-order (as today).
--
-- Balance NEVER changes except through the DEFINER RPCs wallet_credit /
-- wallet_debit below (service-role only). Direct client writes to
-- wallets.balance are blocked by guard_wallet_columns, mirroring the
-- kays_credit hardening in secure_credit.sql. Every mutation is atomic,
-- row-locked, and idempotent on `reference`.
-- ============================================================================

-- ── 1. wallets ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS wallets (
  user_id          uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  balance          numeric(14,2) NOT NULL DEFAULT 0,
  currency         text NOT NULL DEFAULT 'NGN',
  status           text NOT NULL DEFAULT 'active', -- active | frozen
  flw_va_number    text,
  flw_va_bank      text,
  flw_va_reference text,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now()
);

-- ── 2. wallet_transactions (append-only ledger) ─────────────────────────────
CREATE TABLE IF NOT EXISTS wallet_transactions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  amount        numeric(14,2) NOT NULL,        -- signed: +credit / -debit
  balance_after numeric(14,2) NOT NULL,
  type          text NOT NULL,                 -- fund|purchase|escrow_release|withdrawal|refund|reversal|fee
  status        text NOT NULL DEFAULT 'success', -- pending|success|failed
  reference     text UNIQUE,                   -- idempotency key
  order_id      uuid,
  withdrawal_id uuid,
  provider      text,
  provider_ref  text,
  description   text,
  metadata      jsonb DEFAULT '{}',
  created_at    timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_wallet_tx_user_created ON wallet_transactions(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_type         ON wallet_transactions(type);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_order        ON wallet_transactions(order_id);

-- ── 3. withdrawals (vendor payout requests) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS withdrawals (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  amount         numeric(14,2) NOT NULL,
  bank_name      text,
  account_number text,
  account_name   text,
  bank_code      text,
  flw_transfer_id text,
  flw_reference  text UNIQUE,
  status         text NOT NULL DEFAULT 'pending', -- pending|processing|success|failed
  failure_reason text,
  created_at     timestamptz DEFAULT now(),
  updated_at     timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_withdrawals_user   ON withdrawals(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_withdrawals_status ON withdrawals(status);

-- ── 4. guard wallets.balance (defense-in-depth, mirrors secure_credit.sql) ──
-- Only the DEFINER RPCs (which set app.allow_wallet) — or service_role/admin —
-- may change balance/status/flw_* . Everything else raises.
CREATE OR REPLACE FUNCTION guard_wallet_columns()
RETURNS trigger AS $$
BEGIN
  IF auth.role() = 'service_role'
     OR current_setting('app.allow_wallet', true) = '1'
     OR EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  THEN
    RETURN NEW;
  END IF;

  IF NEW.balance          IS DISTINCT FROM OLD.balance
     OR NEW.status           IS DISTINCT FROM OLD.status
     OR NEW.flw_va_number    IS DISTINCT FROM OLD.flw_va_number
     OR NEW.flw_va_bank      IS DISTINCT FROM OLD.flw_va_bank
     OR NEW.flw_va_reference IS DISTINCT FROM OLD.flw_va_reference
  THEN
    RAISE EXCEPTION 'Not allowed to modify protected wallet fields';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_guard_wallet_columns ON wallets;
CREATE TRIGGER trg_guard_wallet_columns
  BEFORE UPDATE ON wallets
  FOR EACH ROW EXECUTE FUNCTION guard_wallet_columns();

-- reuse update_updated_at() from phase4_payments.sql for updated_at bumps
DROP TRIGGER IF EXISTS wallets_updated_at ON wallets;
CREATE TRIGGER wallets_updated_at
  BEFORE UPDATE ON wallets FOR EACH ROW EXECUTE FUNCTION update_updated_at();
DROP TRIGGER IF EXISTS withdrawals_updated_at ON withdrawals;
CREATE TRIGGER withdrawals_updated_at
  BEFORE UPDATE ON withdrawals FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── 5. wallet_credit — service-role only, atomic, idempotent ────────────────
-- Reserves the `reference` in the ledger FIRST (ON CONFLICT DO NOTHING). Only
-- the winning caller mutates the balance, so a replayed webhook or double-tap
-- can never double-credit. Auto-creates the wallet row on first credit.
CREATE OR REPLACE FUNCTION wallet_credit(
  p_user_id       uuid,
  p_amount        numeric,
  p_type          text,
  p_reference     text,
  p_order_id      uuid    DEFAULT NULL,
  p_withdrawal_id uuid    DEFAULT NULL,
  p_provider      text    DEFAULT NULL,
  p_provider_ref  text    DEFAULT NULL,
  p_description   text    DEFAULT NULL,
  p_metadata      jsonb   DEFAULT '{}'
) RETURNS numeric AS $$
DECLARE
  v_tx_id       uuid;
  v_new_balance numeric;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'wallet_credit is service-role only';
  END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Invalid amount'; END IF;
  IF p_reference IS NULL THEN RAISE EXCEPTION 'reference is required for idempotency'; END IF;

  -- Idempotency gate: reserve the reference. Loser returns current balance.
  INSERT INTO wallet_transactions (user_id, amount, balance_after, type, status,
    reference, order_id, withdrawal_id, provider, provider_ref, description, metadata)
  VALUES (p_user_id, p_amount, 0, p_type, 'success',
    p_reference, p_order_id, p_withdrawal_id, p_provider, p_provider_ref, p_description, COALESCE(p_metadata, '{}'))
  ON CONFLICT (reference) DO NOTHING
  RETURNING id INTO v_tx_id;

  IF v_tx_id IS NULL THEN
    SELECT balance INTO v_new_balance FROM wallets WHERE user_id = p_user_id;
    RETURN v_new_balance; -- replay: already processed
  END IF;

  PERFORM set_config('app.allow_wallet', '1', true);
  INSERT INTO wallets (user_id, balance) VALUES (p_user_id, p_amount)
    ON CONFLICT (user_id) DO UPDATE SET balance = wallets.balance + p_amount
    RETURNING balance INTO v_new_balance;

  UPDATE wallet_transactions SET balance_after = v_new_balance WHERE id = v_tx_id;
  RETURN v_new_balance;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION wallet_credit(uuid, numeric, text, text, uuid, uuid, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION wallet_credit(uuid, numeric, text, text, uuid, uuid, text, text, text, jsonb) TO service_role;

-- ── 6. wallet_debit — service-role only, atomic, no overdraw, idempotent ────
-- Returns the new balance, or NULL on insufficient funds (no row mutated). The
-- reserved ledger row is rolled back on insufficient funds so the reference is
-- free to retry after the wallet is topped up.
CREATE OR REPLACE FUNCTION wallet_debit(
  p_user_id      uuid,
  p_amount       numeric,
  p_type         text,
  p_reference    text,
  p_order_id     uuid  DEFAULT NULL,
  p_provider     text  DEFAULT NULL,
  p_provider_ref text  DEFAULT NULL,
  p_description  text  DEFAULT NULL,
  p_metadata     jsonb DEFAULT '{}'
) RETURNS numeric AS $$
DECLARE
  v_tx_id       uuid;
  v_new_balance numeric;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'wallet_debit is service-role only';
  END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Invalid amount'; END IF;
  IF p_reference IS NULL THEN RAISE EXCEPTION 'reference is required for idempotency'; END IF;

  INSERT INTO wallet_transactions (user_id, amount, balance_after, type, status,
    reference, order_id, provider, provider_ref, description, metadata)
  VALUES (p_user_id, -p_amount, 0, p_type, 'success',
    p_reference, p_order_id, p_provider, p_provider_ref, p_description, COALESCE(p_metadata, '{}'))
  ON CONFLICT (reference) DO NOTHING
  RETURNING id INTO v_tx_id;

  IF v_tx_id IS NULL THEN
    SELECT balance INTO v_new_balance FROM wallets WHERE user_id = p_user_id;
    RETURN v_new_balance; -- replay
  END IF;

  PERFORM set_config('app.allow_wallet', '1', true);
  UPDATE wallets SET balance = balance - p_amount
    WHERE user_id = p_user_id AND balance >= p_amount
    RETURNING balance INTO v_new_balance;

  IF v_new_balance IS NULL THEN
    DELETE FROM wallet_transactions WHERE id = v_tx_id; -- undo reservation
    RETURN NULL; -- insufficient funds
  END IF;

  UPDATE wallet_transactions SET balance_after = v_new_balance WHERE id = v_tx_id;
  RETURN v_new_balance;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION wallet_debit(uuid, numeric, text, text, uuid, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION wallet_debit(uuid, numeric, text, text, uuid, text, text, text, jsonb) TO service_role;

-- ── 7. RLS: owners read ONLY their own rows ─────────────────────────────────
-- No INSERT/UPDATE/DELETE policies for authenticated users: every write goes
-- through the DEFINER RPCs / Edge Functions, which run as the service role and
-- bypass RLS. We deliberately do NOT add a `FOR ALL USING (true)` "service"
-- policy — such a policy is permissive across ALL roles and would let any
-- authenticated user read/modify every wallet. The service role needs no
-- policy because it bypasses RLS entirely.
ALTER TABLE wallets              ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE withdrawals          ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Wallet owner read" ON wallets;
CREATE POLICY "Wallet owner read" ON wallets FOR SELECT USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Wallet tx owner read" ON wallet_transactions;
CREATE POLICY "Wallet tx owner read" ON wallet_transactions FOR SELECT USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Withdrawal owner read" ON withdrawals;
CREATE POLICY "Withdrawal owner read" ON withdrawals FOR SELECT USING (user_id = auth.uid());
