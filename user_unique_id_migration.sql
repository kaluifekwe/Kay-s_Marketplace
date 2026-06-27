-- Add unique_id and address columns to users table
ALTER TABLE users ADD COLUMN IF NOT EXISTS unique_id text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS address text;

-- Create unique index on unique_id (allows nulls for existing users)
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_unique_id ON users (unique_id) WHERE unique_id IS NOT NULL;

-- Generate unique 4-digit IDs for existing users who don't have one
DO $$
DECLARE
  rec RECORD;
  new_id text;
  id_exists boolean;
BEGIN
  FOR rec IN SELECT id FROM users WHERE unique_id IS NULL LOOP
    LOOP
      new_id := lpad(floor(random() * 10000)::text, 4, '0');
      SELECT EXISTS(SELECT 1 FROM users WHERE unique_id = new_id) INTO id_exists;
      EXIT WHEN NOT id_exists;
    END LOOP;
    UPDATE users SET unique_id = new_id WHERE id = rec.id;
  END LOOP;
END $$;
