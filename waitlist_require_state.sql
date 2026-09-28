-- Makes state mandatory on every waitlist signup (previously optional).
-- Run this AFTER the frontend/API deploy that already requires it client-side
-- (feat/blog-waitlist-and-hero-images follow-up) — that way there is never a
-- window where the DB rejects a state the form didn't collect.
--
-- Safe to re-run.

-- The only existing NULL-state row was a manual end-to-end test signup
-- (waitlist-test@kaysmarket.com.ng); remove it so the NOT NULL below can be
-- added. If you have real signups with a NULL state you want to keep instead
-- of deleting, backfill them with a real state before running this line.
DELETE FROM waitlist_signups WHERE state IS NULL;

ALTER TABLE waitlist_signups ALTER COLUMN state SET NOT NULL;

DROP POLICY IF EXISTS waitlist_signups_anon_insert ON waitlist_signups;
CREATE POLICY waitlist_signups_anon_insert ON waitlist_signups
  FOR INSERT
  TO anon
  WITH CHECK (
    char_length(email) <= 255
    AND state IN (
      'Abia','Adamawa','Akwa Ibom','Anambra','Bauchi','Bayelsa','Benue',
      'Borno','Cross River','Delta','Ebonyi','Edo','Ekiti','Enugu','FCT',
      'Gombe','Imo','Jigawa','Kaduna','Kano','Katsina','Kebbi','Kogi',
      'Kwara','Lagos','Nasarawa','Niger','Ogun','Ondo','Osun','Oyo',
      'Plateau','Rivers','Sokoto','Taraba','Yobe','Zamfara'
    )
    AND source IN ('blog')
  );

-- ── Roll back ──────────────────────────────────────────────────────────────
--   ALTER TABLE waitlist_signups ALTER COLUMN state DROP NOT NULL;
--   (then re-run waitlist_signups.sql's original policy to restore the optional-state version)
