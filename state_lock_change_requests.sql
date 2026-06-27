-- Allow an 'admin' role so a handful of staff accounts can review
-- state-change requests, without giving every account that power.
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check
  CHECK (role IN ('buyer', 'vendor', 'rider', 'admin'));

CREATE TABLE IF NOT EXISTS state_change_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  current_state text,
  requested_state text NOT NULL,
  reason text NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  admin_note text,
  reviewed_by uuid REFERENCES users(id),
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_state_change_requests_user ON state_change_requests(user_id);
CREATE INDEX IF NOT EXISTS idx_state_change_requests_status ON state_change_requests(status);

ALTER TABLE state_change_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users view own state requests" ON state_change_requests;
CREATE POLICY "Users view own state requests" ON state_change_requests
  FOR SELECT USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Users create own state requests" ON state_change_requests;
CREATE POLICY "Users create own state requests" ON state_change_requests
  FOR INSERT WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Admins view all state requests" ON state_change_requests;
CREATE POLICY "Admins view all state requests" ON state_change_requests
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  );

DROP POLICY IF EXISTS "Admins update state requests" ON state_change_requests;
CREATE POLICY "Admins update state requests" ON state_change_requests
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  );

-- Admins need to be able to apply an approved state change to the
-- requesting user's row, not just their own.
DROP POLICY IF EXISTS "Admins update any user state" ON users;
CREATE POLICY "Admins update any user state" ON users
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  );
