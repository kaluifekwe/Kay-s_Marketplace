-- ============================================================================
-- PAYOUT HOLD ON VENDOR-ARRANGED DELIVERIES
--
-- Background. When a buyer never confirms, auto-release-escrow flags the order
-- for admin review at 24h, notifies every admin and extends release by 12h. At
-- 36h it releases to the vendor whether or not anyone looked.
--
-- On a COURIER order that is defensible: the "delivered" state came from the
-- courier company's own system by server-to-server webhook, so an independent
-- party attested that the parcel arrived. Silence from the buyer is weak
-- evidence against strong evidence.
--
-- On a VENDOR-ARRANGED delivery there is no such attestation. The vendor marked
-- their own order shipped and supplied the only photograph. Releasing on
-- silence pays the vendor on their own word, with an admin push notification as
-- the only check — and a notification nobody opens is not a check.
--
-- So those orders now STOP at 36h instead of paying. They are marked held and
-- wait for a person. The money is not lost and not paid; it is queued for a
-- decision, and that decision is recorded in admin_audit_log.
--
-- Safe to re-run.
-- ============================================================================

alter table public.orders
  add column if not exists payout_held      boolean     not null default false,
  add column if not exists payout_held_at   timestamptz,
  add column if not exists payout_hold_reason text;

comment on column public.orders.payout_held is
  'Vendor-arranged delivery where the buyer never confirmed. Escrow deliberately '
  'NOT auto-released: awaiting an administrator decision. Released only via '
  'admin-release-held-payout, which records who decided and why.';

-- Admins pull this queue constantly; index the small held set rather than
-- scanning orders. Partial index so it stays tiny.
create index if not exists idx_orders_payout_held
  on public.orders(payout_held_at)
  where payout_held = true;

-- Verify:
--   select id, status, delivery_type, payout_held, payout_held_at
--   from public.orders where payout_held = true order by payout_held_at;
