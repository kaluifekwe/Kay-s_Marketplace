-- Stop unauthenticated (anon-key) access to vendor/user contact details.
--
-- WHY: the anon key ships inside the APK, so anyone can extract it and call the
-- REST API directly. Two things were readable that way (per the repo SQL; the
-- live DB is the truth, so run STEP 0 first):
--   1. public_profiles (GRANTed to anon) includes users.phone: every user's
--      personal phone number is harvestable. contact_visibility.sql "step 2"
--      was meant to drop it but was deferred.
--   2. stores has "Stores public read USING (true)" and anon SELECT, so
--      stores.phone / whatsapp_number / address are readable by anyone.
--
-- APP IMPACT (checked against app 1.0.9+14): the app never reads phone or
-- avatar from public_profiles (it selects id/name/last_active/unique_id only)
-- and every stores read happens after login (authenticated). So revoking ANON
-- changes nothing for the current app. Logged-in behaviour is UNCHANGED (a
-- vendor who opts in via show_phone_to_buyers is still shown to logged-in
-- buyers; that is a separate product decision).
-- Older sideloaded builds that still select phone from public_profiles would
-- lose that field (chat names/last-seen keep working).
--
-- Safe to re-run. Run each STEP as its own Run in the Supabase SQL editor.

-- ══ STEP 0 (read-only): see what anon can touch RIGHT NOW ═══════════════════
-- a) Tables/views anon can read:
--   SELECT table_name, privilege_type FROM information_schema.role_table_grants
--   WHERE grantee = 'anon' AND table_schema = 'public' AND privilege_type = 'SELECT'
--   ORDER BY table_name;
-- b) Does the public_profiles view still expose phone?
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='public_profiles';
-- c) Policies on stores:
--   SELECT policyname, roles, cmd, qual FROM pg_policies WHERE tablename = 'stores';

-- ══ STEP 1: public_profiles without phone, and not readable by anon ═════════
-- (CREATE OR REPLACE cannot drop a column from a view, so drop and recreate.)
DROP VIEW IF EXISTS public_profiles;
CREATE VIEW public_profiles WITH (security_barrier = true) AS
  SELECT id, name, last_active, unique_id, avatar_url
  FROM users;
REVOKE ALL ON public_profiles FROM PUBLIC, anon;
GRANT SELECT ON public_profiles TO authenticated;

-- ══ STEP 2: anon may not read stores at all ═════════════════════════════════
-- The website reads web_public_stores (no contact columns); the app reads
-- stores only when logged in. Nothing legitimate needs anon on this table.
REVOKE ALL ON stores FROM anon;

-- ══ STEP 3 (verify; expect the results in the comments) ═════════════════════
--   -- no phone column left in the view (expect 0 rows):
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='public_profiles' AND column_name='phone';
--   -- anon has no grant on stores or public_profiles (expect 0 rows):
--   SELECT table_name FROM information_schema.role_table_grants
--   WHERE grantee='anon' AND table_schema='public' AND table_name IN ('stores','public_profiles');
--   -- authenticated still can (expect 2+ rows):
--   SELECT table_name FROM information_schema.role_table_grants
--   WHERE grantee='authenticated' AND table_schema='public'
--     AND table_name IN ('stores','public_profiles') AND privilege_type='SELECT';

-- ══ Roll back ═══════════════════════════════════════════════════════════════
--   GRANT SELECT ON stores TO anon;
--   DROP VIEW IF EXISTS public_profiles;
--   CREATE VIEW public_profiles AS
--     SELECT id, name, phone, last_active, unique_id, avatar_url FROM users;
--   GRANT SELECT ON public_profiles TO anon, authenticated;
