-- Schedule payout reconciliation: sweep withdrawals still shown as in-flight,
-- ask Flutterwave what actually happened, and finalise or raise an exception.
--
-- Every 30 minutes. Payout webhooks normally land in seconds, so this is a
-- safety net rather than the primary path — and the job itself skips anything
-- younger than 15 minutes so it never races a webhook that is simply in transit.
--
-- Requires pg_cron + pg_net (Database > Extensions). Paste your SERVICE ROLE
-- key into the Authorization header below before running — do NOT commit it.
-- Run once in the Supabase SQL Editor.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

SELECT cron.schedule(
  'reconcile-payouts-job',
  '*/30 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://takuhbkpagvhmxsncdls.supabase.co/functions/v1/reconcile-payouts',
    headers := jsonb_build_object(
      'Authorization', 'Bearer <PASTE_SERVICE_ROLE_KEY_HERE>',
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- Collections: the other direction. Flutterwave took the customer's money but
-- the checkout webhook never created the orders — the buyer paid and got
-- nothing, with nothing in our records showing a problem. Hourly is enough:
-- this is a safety net, and the job only reports (it never creates orders).
SELECT cron.schedule(
  'reconcile-collections-job',
  '7 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://takuhbkpagvhmxsncdls.supabase.co/functions/v1/reconcile-collections',
    headers := jsonb_build_object(
      'Authorization', 'Bearer <PASTE_SERVICE_ROLE_KEY_HERE>',
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- To remove later:
-- SELECT cron.unschedule('reconcile-payouts-job');
-- SELECT cron.unschedule('reconcile-collections-job');

-- To check it is running:
--   select jobname, schedule, active from cron.job where jobname = 'reconcile-payouts-job';
--   select status, count(*) from public.reconciliation_exceptions group by status;
