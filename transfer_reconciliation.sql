-- Payout reconciliation: Paystack transfers complete ASYNCHRONOUSLY and can
-- fail later (bank downtime, invalid account — common in NG). Before this, the
-- release transaction was marked 'success' the instant Paystack *accepted* the
-- transfer, so a bounced payout left a vendor marked paid when they weren't.
--
-- Now: release-escrow marks the payout 'processing' on initiation, and the
-- transfer.success / transfer.failed / transfer.reversed webhook flips it to
-- 'paid' / 'failed'. A failed payout reverts payment_released so it can be
-- retried with a fresh transfer reference. Safe to run multiple times.

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS payout_status TEXT,            -- processing | paid | failed | pending_bank
  ADD COLUMN IF NOT EXISTS payout_attempts INT NOT NULL DEFAULT 0;

-- Queue of payouts needing attention (failed transfers, or released-but-no-bank).
CREATE INDEX IF NOT EXISTS idx_orders_payout_attention
  ON orders(payout_status)
  WHERE payout_status IN ('failed', 'pending_bank');

-- Look up the release transaction by its transfer reference from the webhook.
CREATE INDEX IF NOT EXISTS idx_transactions_paystack_reference
  ON transactions(paystack_reference);
