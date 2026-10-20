-- ============================================================================
-- Admin console Phase 2 — read access for enriched views + dashboard stats.
-- Run AFTER admin_read_policies.sql. Read-only; money still moves only through
-- the audited edge functions. Safe to run more than once.
-- ============================================================================

-- Extra SELECT visibility for admins on the tables the enriched detail views
-- need: store names, wallet balances, withdrawals, and payment transactions.
alter table public.stores        enable row level security;
drop policy if exists admin_read_stores on public.stores;
create policy admin_read_stores on public.stores
  for select to authenticated using (public.is_admin());

alter table public.wallets       enable row level security;
drop policy if exists admin_read_wallets on public.wallets;
create policy admin_read_wallets on public.wallets
  for select to authenticated using (public.is_admin());

alter table public.withdrawals   enable row level security;
drop policy if exists admin_read_withdrawals on public.withdrawals;
create policy admin_read_withdrawals on public.withdrawals
  for select to authenticated using (public.is_admin());

alter table public.transactions  enable row level security;
drop policy if exists admin_read_transactions on public.transactions;
create policy admin_read_transactions on public.transactions
  for select to authenticated using (public.is_admin());

-- Wallet ledger (append-only) so the admin can see per-user wallet activity in
-- the user detail view. Read-only; balance still moves only via the DEFINER RPCs.
alter table public.wallet_transactions enable row level security;
drop policy if exists admin_read_wallet_transactions on public.wallet_transactions;
create policy admin_read_wallet_transactions on public.wallet_transactions
  for select to authenticated using (public.is_admin());

-- ----------------------------------------------------------------------------
-- Dashboard KPIs computed server-side in one round-trip. SECURITY DEFINER so
-- it can aggregate across every row, but it hard-gates on is_admin() first so
-- only admins can call it. Returns a single jsonb blob.
-- ----------------------------------------------------------------------------
create or replace function public.admin_dashboard_stats()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  result jsonb;
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;

  select jsonb_build_object(
    'orders_total',       (select count(*) from orders),
    'orders_today',       (select count(*) from orders where created_at >= date_trunc('day', now())),
    'gmv',                (select coalesce(sum(coalesce(total_with_delivery, total)), 0)
                             from orders where paid_at is not null),
    'escrow_held',        (select coalesce(sum(coalesce(total_with_delivery, total)), 0)
                             from orders
                            where payment_released = false
                              and status in ('paid','shipped')),
    'open_disputes',      (select count(*) from disputes
                            where resolved_at is null
                              and coalesce(auto_closed, false) = false),
    'withdrawals_pending_count', (select count(*) from withdrawals where status in ('pending','processing')),
    'withdrawals_pending_sum',   (select coalesce(sum(amount), 0) from withdrawals where status in ('pending','processing')),
    'wallet_liability',   (select coalesce(sum(balance), 0) from wallets),
    'buyers',             (select count(*) from users where role = 'buyer'),
    'vendors',            (select count(*) from users where role = 'vendor')
  ) into result;

  return result;
end;
$$;

revoke all on function public.admin_dashboard_stats() from public;
grant execute on function public.admin_dashboard_stats() to authenticated;
