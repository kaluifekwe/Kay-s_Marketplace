-- ============================================================================
-- REFUND REQUESTS — buyer-initiated refunds now pass admin approval.
-- Run in the Supabase SQL Editor. Safe to re-run.
--
-- Previously a buyer cancelling an order triggered process-refund immediately.
-- Refunds now pay out to the buyer's verified bank account, so they are
-- reviewed first: the buyer raises a request, an administrator approves or
-- rejects it, and only an approval moves money.
--
-- Automated refunds (delivery failed before pickup, expired vendor pickup,
-- dispute resolutions) deliberately do NOT queue here — they are already
-- governed by their own rules and must stay immediate.
--
-- Append-only from the client's perspective: rows are written exclusively by
-- the request-refund and admin-decide-refund edge functions under the service
-- role. There is no client insert/update policy.
-- ============================================================================

create table if not exists public.refund_requests (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.orders(id) on delete cascade,
  buyer_id     uuid not null references public.users(id) on delete cascade,
  amount       numeric(14,2),
  reason       text,
  status       text not null default 'pending',   -- pending | approved | rejected
  admin_id     uuid references public.users(id),
  admin_notes  text,
  decided_at   timestamptz,
  created_at   timestamptz default now(),
  constraint refund_requests_status_check
    check (status in ('pending', 'approved', 'rejected'))
);

-- One live request per order: a buyer cannot queue the same refund twice, and
-- two admins cannot approve duplicates of it.
create unique index if not exists idx_refund_requests_one_pending
  on public.refund_requests(order_id)
  where status = 'pending';

create index if not exists idx_refund_requests_status
  on public.refund_requests(status, created_at desc);
create index if not exists idx_refund_requests_buyer
  on public.refund_requests(buyer_id, created_at desc);

alter table public.refund_requests enable row level security;

-- Buyers see their own requests so the app can show progress.
drop policy if exists refund_requests_owner_read on public.refund_requests;
create policy refund_requests_owner_read on public.refund_requests
  for select to authenticated using (buyer_id = auth.uid());

-- Admins see everything (the approval queue).
drop policy if exists admin_read_refund_requests on public.refund_requests;
create policy admin_read_refund_requests on public.refund_requests
  for select to authenticated using (public.is_admin());

-- No insert/update/delete policy: writes happen only in the audited edge
-- functions, which run as the service role and bypass RLS.

-- Verify:
--   select status, count(*) from public.refund_requests group by status;
