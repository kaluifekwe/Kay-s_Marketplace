-- ============================================================================
-- APP SETTINGS — admin-editable business config (no-code tuning).
-- Run in the Supabase SQL Editor. Safe to re-run.
--
-- Holds BUSINESS config only: fees, timers, limits, feature flags. Secrets
-- (provider API keys, webhook secrets, PIN pepper) deliberately stay in Supabase
-- env vars and must NEVER be moved here — this table is readable by the admin
-- console in the browser.
--
-- Every consumer reads through _shared/settings.ts getSetting(), which falls
-- back DB -> env var -> hardcoded default. So a missing row, a bad value, or an
-- unreachable table leaves behaviour exactly as it is today.
--
-- Writes go through the audited `admin-update-setting` edge function (service
-- role + role='admin' check) — there is deliberately no client write policy.
-- ============================================================================

create table if not exists public.app_settings (
  key         text primary key,
  value       jsonb not null,
  value_type  text not null default 'number',  -- number | boolean | string
  category    text not null default 'general', -- grouping for the admin UI
  description text,
  min_value   numeric,   -- optional guard rails for the admin UI / write fn
  max_value   numeric,
  updated_by  uuid references public.users(id),
  updated_at  timestamptz default now()
);

alter table public.app_settings enable row level security;

-- Admins read; nobody writes from the browser (the edge function uses the
-- service role, which bypasses RLS entirely).
drop policy if exists admin_read_app_settings on public.app_settings;
create policy admin_read_app_settings on public.app_settings
  for select to authenticated using (public.is_admin());

-- ── Seed with the CURRENT live values, so nothing changes on day one ────────
-- ON CONFLICT DO NOTHING: re-running never clobbers a value an admin has since
-- tuned in the console.
insert into public.app_settings (key, value, value_type, category, description, min_value, max_value) values
  ('delivery_fee_markup_pct', '20'::jsonb, 'number', 'delivery',
   'Percent added on top of the courier quote to cover the aggregator''s own service charge.', 0, 100),
  ('delivery_fee_markup_floor', '300'::jsonb, 'number', 'delivery',
   'Minimum naira buffer added to a courier quote. Used when the percentage works out lower.', 0, 5000),
  ('max_delivery_hours', '24'::jsonb, 'number', 'delivery',
   'Only offer couriers that can deliver within this many hours. Slower options are hidden and the order falls back to vendor-arranged delivery.', 1, 168),
  ('delivery_fee_valid_minutes', '60'::jsonb, 'number', 'delivery',
   'How long a quoted delivery fee stays valid before the buyer must re-quote.', 5, 1440),
  ('price_spike_tolerance', '1.5'::jsonb, 'number', 'delivery',
   'Block booking a courier if the re-quote exceeds the paid fee by more than this multiple (1.5 = 50% higher).', 1, 5),
  ('pickup_window_hours', '24'::jsonb, 'number', 'delivery',
   'How long a vendor has to hand the item to a courier before the order auto-cancels and refunds.', 1, 168),
  ('pickup_reminder_before_hours', '12'::jsonb, 'number', 'delivery',
   'Send the vendor a pickup reminder this many hours before the deadline.', 1, 72),
  ('min_withdrawal', '100'::jsonb, 'number', 'wallet',
   'Smallest amount a user may withdraw to their bank.', 1, 100000),
  ('pin_max_attempts', '5'::jsonb, 'number', 'wallet',
   'Wrong withdrawal-PIN attempts before withdrawals lock.', 1, 10),
  ('pin_lock_minutes', '15'::jsonb, 'number', 'wallet',
   'How long withdrawals stay locked after too many wrong PIN attempts.', 1, 1440),
  ('dispute_response_hours', '24'::jsonb, 'number', 'disputes',
   'How long a vendor has to respond to a dispute before it escalates to admin.', 1, 168),
  ('dispute_return_hours', '24'::jsonb, 'number', 'disputes',
   'How long a buyer has to ship an item back after an admin approves a refund with return.', 1, 168),
  ('dispute_vendor_confirm_hours', '24'::jsonb, 'number', 'disputes',
   'How long a vendor has to confirm they received a returned item before the refund auto-processes.', 1, 168),
  ('cashback_enabled', 'false'::jsonb, 'boolean', 'features',
   'Master switch for cashback. Kept off for Play Store personal-account compliance.', null, null),
  ('welcome_credit_amount', '200'::jsonb, 'number', 'features',
   'Kay''s Credit granted to a new buyer at signup.', 0, 10000)
on conflict (key) do nothing;

-- Keep updated_at honest.
drop trigger if exists app_settings_updated_at on public.app_settings;
create trigger app_settings_updated_at
  before update on public.app_settings
  for each row execute function public.update_updated_at();

-- Verify:
--   select key, value, category from public.app_settings order by category, key;
