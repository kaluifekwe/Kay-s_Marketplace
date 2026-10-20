-- ============================================================================
-- RECONCILIATION — exception queue for money that doesn't agree with the
-- provider. Run in the Supabase SQL Editor. Safe to re-run.
--
-- The scheduled reconcile-payouts job sweeps payouts our records still show as
-- in-flight and asks Flutterwave what actually happened. Most resolve
-- themselves (a webhook was simply missed). Anything it CANNOT resolve lands
-- here so it is visible and ages, rather than sitting silently in `processing`
-- forever.
--
-- Written only by the reconcile job under the service role; there is no client
-- write policy. Admins read it and mark items resolved through an audited edge
-- function.
-- ============================================================================

create table if not exists public.reconciliation_exceptions (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null,              -- payout_stuck | payout_unknown_status | ...
  reference     text,                       -- provider reference, where we have one
  target_type   text,                       -- withdrawal | order | charge
  target_id     text,
  amount        numeric(14,2),
  our_state     text,                       -- what our records say
  provider_state text,                      -- what the provider says
  details       text,
  status        text not null default 'open',  -- open | resolved
  resolved_by   uuid references public.users(id),
  resolved_at   timestamptz,
  resolution_note text,
  first_seen_at timestamptz default now(),
  last_seen_at  timestamptz default now(),
  constraint reconciliation_exceptions_status_check
    check (status in ('open', 'resolved'))
);

-- One open exception per target: a job running every 15 minutes must refresh
-- the existing row rather than pile up duplicates for the same problem.
create unique index if not exists idx_recon_one_open
  on public.reconciliation_exceptions(kind, target_id)
  where status = 'open';

create index if not exists idx_recon_status on public.reconciliation_exceptions(status, first_seen_at);

alter table public.reconciliation_exceptions enable row level security;

drop policy if exists admin_read_recon on public.reconciliation_exceptions;
create policy admin_read_recon on public.reconciliation_exceptions
  for select to authenticated using (public.is_admin());

-- Verify:
--   select kind, status, count(*), min(first_seen_at) as oldest
--   from public.reconciliation_exceptions group by kind, status;
