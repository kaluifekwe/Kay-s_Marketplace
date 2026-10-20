-- ============================================================================
-- ADMIN AUDIT LOG — one queryable trail of every admin action.
-- Run in the Supabase SQL Editor. Safe to re-run.
--
-- Admin attribution was scattered and incomplete: disputes.admin_decided_by,
-- app_settings.updated_by and wallet_transactions.metadata.admin_id each held a
-- piece, while withdrawal reconciles, admin-initiated order refunds and escrow
-- releases recorded NOTHING. Admins can move real money, so every action lands
-- here with who did it, to what, and how much.
--
-- Append-only by construction: writes happen only inside the audited edge
-- functions under the service role (which bypasses RLS). There is deliberately
-- no INSERT/UPDATE/DELETE policy, so nothing can be written or rewritten from a
-- browser session — including by an admin covering their tracks.
-- ============================================================================

create table if not exists public.admin_audit_log (
  id          uuid primary key default gen_random_uuid(),
  admin_id    uuid references public.users(id),
  action      text not null,          -- e.g. dispute.approve_refund, wallet.adjust
  target_type text,                   -- dispute | user | order | withdrawal | setting
  target_id   text,
  summary     text,                   -- human-readable one-liner for the console
  metadata    jsonb default '{}',     -- amounts, before/after, reason
  created_at  timestamptz default now()
);

create index if not exists idx_audit_created  on public.admin_audit_log(created_at desc);
create index if not exists idx_audit_admin    on public.admin_audit_log(admin_id, created_at desc);
create index if not exists idx_audit_action   on public.admin_audit_log(action);
create index if not exists idx_audit_target   on public.admin_audit_log(target_type, target_id);

alter table public.admin_audit_log enable row level security;

-- Admins read. No write policy at all — see the note above.
drop policy if exists admin_read_audit_log on public.admin_audit_log;
create policy admin_read_audit_log on public.admin_audit_log
  for select to authenticated using (public.is_admin());

-- Verify:
--   select created_at, action, summary from public.admin_audit_log
--   order by created_at desc limit 20;
