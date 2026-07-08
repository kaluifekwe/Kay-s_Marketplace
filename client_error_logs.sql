-- Remote client error log. The app writes here (best-effort) whenever an
-- uncaught error / render crash happens, so support can see the exact cause
-- without asking the customer. Clients can INSERT but never SELECT — only the
-- service role (Supabase dashboard) reads it. Safe to re-run.

CREATE TABLE IF NOT EXISTS client_error_logs (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     uuid,
  context     text,
  message     text,
  stack       text,
  platform    text,
  app_version text,
  created_at  timestamptz DEFAULT now()
);

ALTER TABLE client_error_logs ENABLE ROW LEVEL SECURITY;

-- Insert-only for app users (errors can happen before login, so anon too).
-- No SELECT policy → clients can never read the log; the dashboard still can.
DROP POLICY IF EXISTS "clients can log errors" ON client_error_logs;
CREATE POLICY "clients can log errors" ON client_error_logs
  FOR INSERT TO authenticated, anon WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_client_error_logs_created ON client_error_logs (created_at DESC);

NOTIFY pgrst, 'reload schema';
