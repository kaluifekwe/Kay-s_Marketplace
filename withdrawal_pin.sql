-- Withdrawal PIN (4-digit) for vendors/buyers. Safe to re-run.
--
-- The PIN hash is set by the withdrawal-pin Edge Function and verified by
-- wallet-withdraw (both service-role). RLS is enabled with NO policies, so
-- clients can never read the hash or attempt/lockout state — only the service
-- role (Edge Functions) touches this table.

CREATE TABLE IF NOT EXISTS withdrawal_pins (
  user_id         uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  pin_hash        text NOT NULL,
  failed_attempts int  NOT NULL DEFAULT 0,
  locked_until    timestamptz,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

ALTER TABLE withdrawal_pins ENABLE ROW LEVEL SECURITY;
-- (no policies → deny all for anon/authenticated; service role bypasses RLS)

NOTIFY pgrst, 'reload schema';
