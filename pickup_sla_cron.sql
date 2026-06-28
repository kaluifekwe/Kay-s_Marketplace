-- Schedule the pickup-SLA job: remind vendors, then auto-cancel + refund
-- courier orders never sent for pickup. Runs every 15 minutes (pickup
-- deadlines are hour-scale, so 15 min is plenty).
--
-- Requires pg_cron + pg_net (Database > Extensions). Paste your SERVICE ROLE
-- key into the Authorization header below before running — do NOT commit it.
-- Run once in the Supabase SQL Editor.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

SELECT cron.schedule(
  'expire-unbooked-pickups-job',
  '*/15 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://takuhbkpagvhmxsncdls.supabase.co/functions/v1/expire-unbooked-pickups',
    headers := jsonb_build_object(
      'Authorization', 'Bearer <PASTE_SERVICE_ROLE_KEY_HERE>',
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- To remove later:
-- SELECT cron.unschedule('expire-unbooked-pickups-job');
