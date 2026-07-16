-- Schedule the Shipbubble delivery-status poller (resilience twin of
-- poll-terminal-deliveries-job) WITHOUT hand-typing the service-role key.
--
-- It derives the command from the already-working poll-terminal-deliveries-job
-- and rewrites 'terminal' -> 'shipbubble' throughout. That single swap covers
-- both places the word appears in that job's command:
--   1. the function URL  .../functions/v1/poll-terminal-deliveries
--   2. the activity gate  ... provider = 'terminal' ...  (only fire when a ride
--      of THIS provider is actually in flight)
-- so the new job inherits the identical auth header, URL base and gating shape,
-- just pointed at Shipbubble. cron.schedule() upserts by jobname, so re-running
-- this is safe/idempotent. Runs as ONE self-contained block (the SQL editor
-- auto-commits a successful run; don't split across Runs).
--
-- PRE-CHECK (optional, run first to eyeball the source command):
--   select jobname, schedule, command from cron.job
--   where jobname = 'poll-terminal-deliveries-job';

do $$
declare
  src_cmd  text;
  new_cmd  text;
begin
  select command into src_cmd
  from cron.job
  where jobname = 'poll-terminal-deliveries-job';

  if src_cmd is null then
    raise exception
      'poll-terminal-deliveries-job not found — cannot derive the shipbubble cron. Create the terminal poller cron first.';
  end if;

  new_cmd := replace(src_cmd, 'terminal', 'shipbubble');

  -- Show what we are about to schedule so it can be eyeballed in the output.
  raise notice 'poll-shipbubble-deliveries-job command: %', new_cmd;

  perform cron.schedule('poll-shipbubble-deliveries-job', '*/10 * * * *', new_cmd);
end $$;

-- Verify:
--   select jobname, schedule, active, command from cron.job
--   where jobname in ('poll-terminal-deliveries-job','poll-shipbubble-deliveries-job');
