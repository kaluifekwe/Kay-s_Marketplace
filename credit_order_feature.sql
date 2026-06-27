-- ============================================
-- Kay's Credit checkout fix — supporting RPC
-- Run in Supabase SQL Editor (or via CLI). Safe to re-run.
-- ============================================

-- cashback-credit and complete-credit-order both call this RPC to add
-- credit back to a buyer atomically (cashback award, or rollback if a
-- credit-paid order fails to create after the credit was deducted).
-- Previously this RPC didn't exist; both functions silently fell back to
-- a non-atomic read-then-update, which is what spend_kays_credit's
-- sibling fix (security_fixes_critical.sql) was meant to close everywhere.
CREATE OR REPLACE FUNCTION increment_kays_credit(p_user_id uuid, p_amount numeric)
RETURNS numeric AS $$
  UPDATE users
  SET kays_credit = kays_credit + p_amount
  WHERE id = p_user_id
  RETURNING kays_credit;
$$ LANGUAGE sql;
