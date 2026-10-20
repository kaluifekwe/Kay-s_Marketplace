-- ============================================================================
-- APP SETTINGS — wiring two knobs that the edge functions can't reach.
-- Run in the Supabase SQL Editor. Safe to re-run. Applied 2026-07-19.
--
-- Most app_settings values are read by edge functions through
-- _shared/settings.ts. Two are not, because the values are applied inside the
-- database (a signup trigger) or by the mobile client (which deliberately has
-- no read access to app_settings — that table is admin-read only).
--
-- Both were seeded and shown in the admin console while having NO effect:
-- changing them looked like it worked and silently did nothing. These triggers
-- make them real, and move the decision server-side where it belongs.
-- ============================================================================

-- ── welcome_credit_amount ───────────────────────────────────────────────────
-- The signup trigger previously hardcoded 200 in two places. It now reads the
-- configured amount, falls back to 200 if the row is missing or unreadable (so
-- signup can never break because of a settings problem), and treats 0 as
-- "welcome credit disabled".
create or replace function grant_welcome_credit()
returns trigger as $$
declare
  v_amount numeric;
begin
  if new.role = 'buyer' then
    begin
      select (value #>> '{}')::numeric into v_amount
        from public.app_settings where key = 'welcome_credit_amount';
    exception when others then
      v_amount := null;
    end;
    v_amount := coalesce(v_amount, 200);

    if v_amount > 0 then
      perform set_config('app.allow_credit', '1', true);
      update users set kays_credit = coalesce(kays_credit, 0) + v_amount where id = new.id;
      insert into credit_transactions (buyer_id, amount, type, description, expires_at)
        values (new.id, v_amount, 'cashback',
                '₦' || trim(to_char(v_amount, 'FM999,999,990')) || ' welcome bonus',
                now() + interval '90 days');
    end if;
  end if;
  return null;
end;
$$ language plpgsql security definer;

-- Trigger itself is unchanged (see secure_credit.sql); replacing the function
-- is enough.

-- ── dispute_response_hours ──────────────────────────────────────────────────
-- The vendor-response deadline was computed in the Flutter client (a hardcoded
-- 24h). The client cannot read app_settings, so the knob did nothing. Compute
-- it here instead: on insert, and whenever the deadline is being reset (e.g. a
-- buyer rejects a replacement and the vendor gets a fresh window). This also
-- means the server owns the deadline rather than trusting the client's value.
create or replace function public.set_dispute_response_deadline()
returns trigger as $$
declare
  v_hours numeric;
begin
  begin
    select (value #>> '{}')::numeric into v_hours
      from public.app_settings where key = 'dispute_response_hours';
  exception when others then
    v_hours := null;
  end;
  v_hours := coalesce(v_hours, 24);

  if tg_op = 'INSERT' then
    new.vendor_response_deadline := now() + make_interval(hours => v_hours::int);
  elsif new.vendor_response_deadline is distinct from old.vendor_response_deadline
        and new.vendor_response_deadline is not null then
    new.vendor_response_deadline := now() + make_interval(hours => v_hours::int);
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_dispute_response_deadline on public.disputes;
create trigger trg_dispute_response_deadline
  before insert or update on public.disputes
  for each row execute function public.set_dispute_response_deadline();

-- ── remove a knob with no consumer ──────────────────────────────────────────
-- courier_balance_warn_threshold drove a courier wallet-balance dashboard card
-- that was removed. Nothing reads it, so it should not sit in the console
-- looking like a working control.
delete from public.app_settings where key = 'courier_balance_warn_threshold';

-- Verify every remaining key is genuinely consumed:
--   select key, value, category from public.app_settings order by category, key;
