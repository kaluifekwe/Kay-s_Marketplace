-- ============================================================================
-- Bootstrap the first admin(s) for the Kays Market admin console.
-- ----------------------------------------------------------------------------
-- The guard trigger on `users` only allows role changes from `service_role`
-- or an EXISTING admin. There is no admin yet, and the SQL editor has neither
-- context, so a plain UPDATE is blocked. We disable user triggers on `users`
-- for one bootstrap update, then turn them straight back on.
-- ============================================================================

-- STEP 1 — PREVIEW. Run this ALONE first and confirm these are the right
-- accounts (admin = full financial control, so promote deliberately).
SELECT id, email, role FROM users WHERE email ILIKE 'oyemechi%';

-- STEP 2 — PROMOTE. Run this block once the preview looks right.
ALTER TABLE users DISABLE TRIGGER USER;
UPDATE users SET role = 'admin'
  WHERE email ILIKE 'oyemechi%'
  RETURNING id, email, role;
ALTER TABLE users ENABLE TRIGGER USER;
