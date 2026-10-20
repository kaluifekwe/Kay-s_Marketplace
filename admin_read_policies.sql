-- ============================================================================
-- Admin read access for the Kays Market admin console (dispatch-admin)
-- ----------------------------------------------------------------------------
-- The console logs in as a normal Supabase auth user and reads data with the
-- PUBLIC anon key, so Row-Level Security still applies. These policies let a
-- user whose users.role = 'admin' READ every row in the core tables, while
-- everyone else stays restricted to their own rows by the existing policies.
--
-- Money mutations are NOT granted here — those keep flowing only through the
-- audited edge functions (service role). This file grants read visibility only.
--
-- Safe to run more than once (drops-then-creates each policy).
-- ============================================================================

-- is_admin(): SECURITY DEFINER so the inner lookup bypasses RLS on `users`,
-- which avoids infinite recursion when a policy ON users needs to check the
-- caller's role.
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.users
    where id = auth.uid() and role = 'admin'
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- USERS -----------------------------------------------------------------------
alter table public.users enable row level security;
drop policy if exists admin_read_users on public.users;
create policy admin_read_users on public.users
  for select to authenticated
  using (public.is_admin());

-- ORDERS ----------------------------------------------------------------------
alter table public.orders enable row level security;
drop policy if exists admin_read_orders on public.orders;
create policy admin_read_orders on public.orders
  for select to authenticated
  using (public.is_admin());

-- DISPUTES --------------------------------------------------------------------
alter table public.disputes enable row level security;
drop policy if exists admin_read_disputes on public.disputes;
create policy admin_read_disputes on public.disputes
  for select to authenticated
  using (public.is_admin());
