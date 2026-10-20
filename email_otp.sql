-- Email OTP verification (Phase 1 of email auth). New buyers/vendors get a
-- 6-digit code by email (via Resend) at signup and must enter it before they
-- can use the app. Codes are stored HASHED, expire fast, and are attempt-
-- limited. Only the send-otp / verify-otp Edge Functions (service role) touch
-- the table. Safe to re-run.

-- 1) Verification flag on the user.
--    Adding the column with DEFAULT true backfills EXISTING users as verified
--    (grandfathered — we don't lock out anyone who already signed up). Then we
--    flip the default to false so NEW signups start unverified.
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified boolean NOT NULL DEFAULT true;
ALTER TABLE users ALTER COLUMN email_verified SET DEFAULT false;

-- 2) OTP store (one live code per user; old unconsumed ones are cleared on resend).
CREATE TABLE IF NOT EXISTS email_otps (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL,
  email       text NOT NULL,
  code_hash   text NOT NULL,
  expires_at  timestamptz NOT NULL,
  attempts    int NOT NULL DEFAULT 0,
  consumed_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_email_otps_user ON email_otps (user_id, created_at DESC);

-- RLS on with NO policies = deny all for anon/authenticated. The Edge Functions
-- use the service role, which bypasses RLS, so only they can read/write codes.
ALTER TABLE email_otps ENABLE ROW LEVEL SECURITY;

NOTIFY pgrst, 'reload schema';
