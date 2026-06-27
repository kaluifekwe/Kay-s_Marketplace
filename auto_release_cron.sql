-- ============================================
-- Schedule server-side escrow auto-release + dispute auto-escalation.
--
-- Previously these only ran from a Dart Timer inside the app
-- (EscrowService / OrderCubit._rescheduleAutoReleaseTimers). If no one
-- opened the app near the 24h/48h deadline, payment release or dispute
-- escalation simply never happened. This runs every 5 minutes on the
-- server regardless of whether the app is open.
--
-- Run this in Supabase SQL Editor. Requires the pg_cron and pg_net
-- extensions (enable them under Database > Extensions if not already on).
-- ============================================

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Replace the placeholders below with your actual project values before
-- running. The service role key must NOT be committed to source control —
-- paste it directly into the SQL editor when you run this once.
SELECT cron.schedule(
  'auto-release-escrow-job',
  '*/5 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://takuhbkpagvhmxsncdls.supabase.co/functions/v1/auto-release-escrow',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ',
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- To remove the schedule later:
-- SELECT cron.unschedule('auto-release-escrow-job');
