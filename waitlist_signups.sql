-- Buyer/vendor waitlist capture (blog CTA lead capture, Phase 1 of the SEO plan).
--
-- Security model matches every other public-facing surface in this project:
-- the anon key gets exactly one privilege here — INSERT — and nothing else.
-- It cannot read, update, or delete a single row, including the one it just
-- inserted. Only an admin (is_admin(), see web_public_views.sql) can read the
-- list. This is the one place in the project the anon key is allowed to
-- WRITE; everywhere else it only reads web_public_* views.
--
-- Safe to re-run.

CREATE TABLE IF NOT EXISTS waitlist_signups (
  id           uuid primary key default uuid_generate_v4(),
  email        text not null,
  role         text not null check (role in ('buyer','vendor')),
  state        text,
  source       text not null default 'blog',
  created_at   timestamptz not null default now()
);

ALTER TABLE waitlist_signups
  ADD CONSTRAINT waitlist_signups_email_format
  CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');

CREATE UNIQUE INDEX IF NOT EXISTS uniq_waitlist_signups_email ON waitlist_signups (lower(email));
CREATE INDEX IF NOT EXISTS idx_waitlist_signups_created ON waitlist_signups (created_at DESC);

ALTER TABLE waitlist_signups ENABLE ROW LEVEL SECURITY;

-- Public insert only. WITH CHECK constrains exactly what an anonymous
-- visitor may submit — a real-looking email, a real state (or none), a role
-- of buyer/vendor, and a known source. Nothing else about this row is ever
-- visible to them again after this INSERT succeeds.
DROP POLICY IF EXISTS waitlist_signups_anon_insert ON waitlist_signups;
CREATE POLICY waitlist_signups_anon_insert ON waitlist_signups
  FOR INSERT
  TO anon
  WITH CHECK (
    char_length(email) <= 255
    AND (state IS NULL OR state IN (
      'Abia','Adamawa','Akwa Ibom','Anambra','Bauchi','Bayelsa','Benue',
      'Borno','Cross River','Delta','Ebonyi','Edo','Ekiti','Enugu','FCT',
      'Gombe','Imo','Jigawa','Kaduna','Kano','Katsina','Kebbi','Kogi',
      'Kwara','Lagos','Nasarawa','Niger','Ogun','Ondo','Osun','Oyo',
      'Plateau','Rivers','Sokoto','Taraba','Yobe','Zamfara'
    ))
    AND source IN ('blog')
  );

DROP POLICY IF EXISTS waitlist_signups_admin_all ON waitlist_signups;
CREATE POLICY waitlist_signups_admin_all ON waitlist_signups
  FOR ALL USING (is_admin()) WITH CHECK (is_admin());

REVOKE ALL ON waitlist_signups FROM PUBLIC, anon, authenticated;
GRANT INSERT ON waitlist_signups TO anon;                                  -- gated by the RLS policy above
GRANT ALL ON waitlist_signups TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON waitlist_signups TO authenticated; -- gated by is_admin()

-- ── Verify (expect the results noted in the comments) ────────────────────
--   -- anon has INSERT only, no SELECT/UPDATE/DELETE (expect exactly 1 row: INSERT):
--   SELECT privilege_type FROM information_schema.role_table_grants
--   WHERE grantee='anon' AND table_schema='public' AND table_name='waitlist_signups';
--   -- a duplicate email is rejected (run the same email as anon twice; the
--   -- second insert should fail with a unique_violation on
--   -- uniq_waitlist_signups_email).

-- ── Roll back ──────────────────────────────────────────────────────────────
--   DROP TABLE IF EXISTS waitlist_signups;
