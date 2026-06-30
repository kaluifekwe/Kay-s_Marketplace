-- Stop exposing full user rows. "Users read others" = USING(true) let any
-- logged-in user read EVERY column of EVERY user (email, phone, NIN,
-- kays_credit, role). Expose only non-sensitive profile fields via a view; the
-- app's cross-user name/contact lookups read this instead of `users`.
-- Run order: apply this + ship the app build that reads public_profiles, THEN
-- drop the wide-open policy (last statement, commented) once verified.

CREATE OR REPLACE VIEW public_profiles AS
  SELECT id, name, phone, last_active, unique_id
  FROM users;

GRANT SELECT ON public_profiles TO anon, authenticated;

-- Admins still need full user rows (admin screens show email). A SECURITY
-- DEFINER helper checks the role without recursing into users' RLS.
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean AS $$
  SELECT EXISTS (SELECT 1 FROM users WHERE id = auth.uid() AND role = 'admin');
$$ LANGUAGE sql SECURITY DEFINER STABLE;

DROP POLICY IF EXISTS "Admins read all users" ON users;
CREATE POLICY "Admins read all users" ON users
  FOR SELECT USING (is_admin());

-- ⚠️ Run this ONLY after the app build that reads public_profiles is live
-- (otherwise cross-user name lookups in the current app return nothing):
--
--   DROP POLICY IF EXISTS "Users read others" ON users;
--
-- After dropping it, a normal user can read only their OWN users row
-- ("Users read own") + everyone's public_profiles. Email/NIN/credit/role are
-- no longer harvestable.
