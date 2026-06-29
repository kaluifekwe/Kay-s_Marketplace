-- Policy acceptance gate: buyers and vendors must read and accept the Buyer &
-- Vendor Agreement before using the app. One immutable row per user + policy
-- version, so bumping the version (in app_policy.dart) forces re-acceptance.
-- Safe to run multiple times.

CREATE TABLE IF NOT EXISTS policy_acceptances (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
  role TEXT NOT NULL,                       -- 'buyer' | 'vendor'
  policy_version TEXT NOT NULL,             -- matches kPolicyVersion in the app
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One acceptance per user per version — makes the client write idempotent and
-- lets the gate check "has this user accepted the current version?" cheaply.
CREATE UNIQUE INDEX IF NOT EXISTS uniq_policy_acceptance_user_version
  ON policy_acceptances(user_id, policy_version);

ALTER TABLE policy_acceptances ENABLE ROW LEVEL SECURITY;

-- A user can read and record only their own acceptance. There is deliberately
-- no UPDATE/DELETE policy: acceptances are an immutable audit record (service
-- role bypasses RLS for any admin/maintenance need).
DROP POLICY IF EXISTS policy_acceptances_owner_read ON policy_acceptances;
CREATE POLICY policy_acceptances_owner_read ON policy_acceptances
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS policy_acceptances_owner_insert ON policy_acceptances;
CREATE POLICY policy_acceptances_owner_insert ON policy_acceptances
  FOR INSERT WITH CHECK (auth.uid() = user_id);
