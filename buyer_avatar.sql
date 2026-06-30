-- Buyer (and vendor) profile picture. avatar_url is the user's own field — they
-- can set it via "Users update own" RLS; it is intentionally NOT in the column
-- guard. Image is uploaded to storage; only the URL is stored here.
-- Safe to re-run.

ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT;
