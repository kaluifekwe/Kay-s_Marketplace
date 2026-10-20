-- Poll Terminal Africa delivery status every 10 minutes. Fallback for accounts
-- where the Terminal webhook can't be registered (their webhook-create API
-- errors). The function GETs each active Terminal shipment and, on a status
-- change, applies it exactly like the webhook would (delivered -> starts the 24h
-- escrow clock). Run ONCE in the Supabase SQL editor. Paste your SERVICE ROLE
-- key where shown — do NOT commit it to source control.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Activity-gated: the WHERE EXISTS means net.http_post (the actual poll) only
-- fires when there's at least one ACTIVE Terminal delivery in flight. When the
-- marketplace is quiet the cron just runs a cheap check and does nothing — no
-- wasted function invocations or Terminal API calls.
SELECT cron.schedule(
  'poll-terminal-deliveries-job',
  '*/10 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://takuhbkpagvhmxsncdls.supabase.co/functions/v1/poll-terminal-deliveries',
    headers := jsonb_build_object(
      'Authorization', 'Bearer <PASTE_SERVICE_ROLE_KEY_HERE>',
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  )
  WHERE EXISTS (
    SELECT 1 FROM public.deliveries
    WHERE provider = 'terminal'
      AND status NOT IN ('delivered','cancelled','failed')
  );
  $$
);

-- To remove later:
-- SELECT cron.unschedule('poll-terminal-deliveries-job');
