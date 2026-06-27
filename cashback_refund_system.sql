-- Cashback & Bank Transfer Refund System
-- Run in Supabase SQL Editor

-- 1. Add kays_credit to users
ALTER TABLE users ADD COLUMN IF NOT EXISTS kays_credit NUMERIC DEFAULT 0;

-- 2. Add refunded_at to orders
ALTER TABLE orders ADD COLUMN IF NOT EXISTS refunded_at TIMESTAMPTZ;

-- 3. Credit transactions table
CREATE TABLE IF NOT EXISTS credit_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  buyer_id UUID NOT NULL REFERENCES users(id),
  amount NUMERIC NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('cashback', 'refund', 'used', 'expiry')),
  order_id TEXT,
  description TEXT,
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_credit_tx_buyer ON credit_transactions(buyer_id);
CREATE INDEX IF NOT EXISTS idx_credit_tx_type ON credit_transactions(type);

-- 4. Buyer bank accounts table
CREATE TABLE IF NOT EXISTS buyer_bank_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  buyer_id UUID NOT NULL REFERENCES users(id) UNIQUE,
  bank_name TEXT NOT NULL,
  bank_code TEXT NOT NULL,
  account_number TEXT NOT NULL,
  account_name TEXT NOT NULL,
  paystack_recipient_code TEXT,
  is_verified BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. RLS policies
ALTER TABLE credit_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE buyer_bank_accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Buyers read own credits" ON credit_transactions
  FOR SELECT USING (buyer_id = auth.uid());

CREATE POLICY "Service insert credits" ON credit_transactions
  FOR INSERT WITH CHECK (true);

CREATE POLICY "Buyers read own bank" ON buyer_bank_accounts
  FOR SELECT USING (buyer_id = auth.uid());

CREATE POLICY "Buyers upsert own bank" ON buyer_bank_accounts
  FOR INSERT WITH CHECK (buyer_id = auth.uid());

CREATE POLICY "Buyers update own bank" ON buyer_bank_accounts
  FOR UPDATE USING (buyer_id = auth.uid());
