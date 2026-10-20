-- Vendor KYC + dual-role NIN policy. Safe to re-run.
--
-- A person may be BOTH a verified buyer and a verified vendor with the SAME
-- NIN/BVN (two separate accounts — one per role), but NOT two accounts of the
-- same role. So the old "one verified account per NIN" rule is replaced by a
-- per-(nin, role) rule. The verify-nin Edge Function enforces the same scoping
-- at the application layer; this index makes it race-proof at the DB level.

DROP INDEX IF EXISTS uniq_verified_nin;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_verified_nin_role
  ON users (nin, role)
  WHERE nin IS NOT NULL AND kyc_status = 'verified';
