-- ============================================
-- PHASE 4: PAYMENTS — PAYSTACK INTEGRATION
-- Run this in Supabase SQL Editor
-- ============================================

-- 1. Transactions table (full audit trail)
CREATE TABLE IF NOT EXISTS transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid REFERENCES orders(id) ON DELETE SET NULL,
  buyer_id uuid REFERENCES users(id) ON DELETE SET NULL,
  vendor_id uuid REFERENCES users(id) ON DELETE SET NULL,
  store_id uuid REFERENCES stores(id) ON DELETE SET NULL,
  amount numeric NOT NULL,
  platform_fee numeric NOT NULL DEFAULT 0,
  vendor_payout numeric NOT NULL DEFAULT 0,
  paystack_reference text UNIQUE,
  paystack_access_code text,
  paystack_authorization_url text,
  channel text DEFAULT 'card',
  status text NOT NULL DEFAULT 'pending', -- pending, success, failed, refund, released
  type text NOT NULL DEFAULT 'payment',   -- payment, release, refund
  metadata jsonb DEFAULT '{}',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 2. Vendor bank accounts table
CREATE TABLE IF NOT EXISTS vendor_bank_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  bank_name text NOT NULL,
  bank_code text NOT NULL,
  account_number text NOT NULL,
  account_name text NOT NULL DEFAULT '',
  paystack_recipient_code text,
  is_verified boolean DEFAULT false,
  locked_until timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 3. Add paystack_reference to orders
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'orders' AND column_name = 'paystack_reference'
  ) THEN
    ALTER TABLE orders ADD COLUMN paystack_reference text;
  END IF;
END $$;

-- 4. Add paystack_reference to orders (unique index for idempotency)
CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_paystack_reference
  ON orders(paystack_reference) WHERE paystack_reference IS NOT NULL;

-- 5. Indexes for transactions
CREATE INDEX IF NOT EXISTS idx_transactions_order_id ON transactions(order_id);
CREATE INDEX IF NOT EXISTS idx_transactions_buyer_id ON transactions(buyer_id);
CREATE INDEX IF NOT EXISTS idx_transactions_vendor_id ON transactions(vendor_id);
CREATE INDEX IF NOT EXISTS idx_transactions_status ON transactions(status);
CREATE INDEX IF NOT EXISTS idx_transactions_paystack_ref ON transactions(paystack_reference);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at DESC);

-- 6. Indexes for vendor_bank_accounts
CREATE INDEX IF NOT EXISTS idx_vendor_bank_accounts_user ON vendor_bank_accounts(user_id);

-- 7. RLS policies for transactions
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;

-- Buyers can view their own transactions
CREATE POLICY "Buyers view own transactions"
  ON transactions FOR SELECT
  USING (auth.uid() = buyer_id);

-- Vendors can view transactions for their orders
CREATE POLICY "Vendors view own transactions"
  ON transactions FOR SELECT
  USING (auth.uid() = vendor_id);

-- Service role can insert/update (Edge Functions use service role)
CREATE POLICY "Service role manages transactions"
  ON transactions FOR ALL
  USING (true)
  WITH CHECK (true);

-- 8. RLS policies for vendor_bank_accounts
ALTER TABLE vendor_bank_accounts ENABLE ROW LEVEL SECURITY;

-- Vendors can view their own bank account
CREATE POLICY "Vendors view own bank account"
  ON vendor_bank_accounts FOR SELECT
  USING (auth.uid() = user_id);

-- Vendors can insert their own bank account
CREATE POLICY "Vendors insert own bank account"
  ON vendor_bank_accounts FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Vendors can update their own bank account (locked_until prevents changes within 24h)
CREATE POLICY "Vendors update own bank account"
  ON vendor_bank_accounts FOR UPDATE
  USING (auth.uid() = user_id);

-- Service role can manage all (Edge Functions)
CREATE POLICY "Service role manages bank accounts"
  ON vendor_bank_accounts FOR ALL
  USING (true)
  WITH CHECK (true);

-- 9. Function to check if vendor bank account is locked
CREATE OR REPLACE FUNCTION is_bank_account_locked(p_user_id uuid)
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM vendor_bank_accounts
    WHERE user_id = p_user_id
    AND locked_until IS NOT NULL
    AND locked_until > now()
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 10. Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 11. Triggers for updated_at
CREATE TRIGGER transactions_updated_at
  BEFORE UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER vendor_bank_accounts_updated_at
  BEFORE UPDATE ON vendor_bank_accounts
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
