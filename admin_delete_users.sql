-- admin_delete_users.sql
-- Hard-delete user accounts by email (run as service_role / SQL editor).
-- Frees the email for re-registration by removing BOTH public.users AND
-- auth.users (email is UNIQUE in each; a re-signup fails if either row lingers).
--
-- ⚠ These look like VENDOR accounts. Deleting a vendor cascade-removes their
--   store, products, orders, disputes, reviews, chats and wallet. This is
--   PERMANENT. Run SECTION 1 first and confirm each account is safe to wipe.
--
-- public.users has NO foreign key to auth.users and several child tables lack
-- ON DELETE CASCADE, so this script tears rows down in child -> parent order.

-- =====================================================================
-- SECTION 1 - IMPACT CHECK  (read-only; run this FIRST)
-- =====================================================================
with targets as (
  select id, email, role, store_id
  from public.users
  where lower(email) = any (array[
    'blancofashionworld@gmail.com',
    'ogeezapparells@gmail.com',
    'ucheamadik@gmail.com'
  ])
)
select
  t.email,
  t.role,
  (select count(*) from public.orders   o  where o.vendor_id = t.id or o.buyer_id = t.id) as orders,
  (select count(*) from public.deliveries d where d.vendor_id = t.id or d.buyer_id = t.id) as deliveries,
  (select count(*) from public.disputes di  where di.vendor_id = t.id or di.buyer_id = t.id) as disputes,
  (select count(*) from public.products p
     join public.stores s on s.id = p.store_id where s.vendor_id = t.id)                    as products,
  coalesce((select balance from public.wallets w where w.user_id = t.id), 0)               as wallet_balance,
  coalesce(t.kays_credit, 0)                                                                as kays_credit
from targets t
order by t.email;

-- Also list any of the three emails that exist ONLY in auth (no public.users row):
select u.email
from auth.users u
where lower(u.email) = any (array[
  'blancofashionworld@gmail.com','ogeezapparells@gmail.com','ucheamadik@gmail.com'])
  and not exists (select 1 from public.users p where p.id = u.id);


-- =====================================================================
-- SECTION 2 - DELETION  (DESTRUCTIVE)
-- Wrapped in one transaction: if any FK error is raised, NOTHING is
-- committed. Review the NOTICE output, then COMMIT only if it looks right.
-- =====================================================================
begin;

do $$
declare
  v_emails text[] := array[
    'blancofashionworld@gmail.com',
    'ogeezapparells@gmail.com',
    'ucheamadik@gmail.com'
  ];
  v_email text;
  v_id    uuid;
begin
  foreach v_email in array v_emails loop
    select id into v_id from public.users where lower(email) = lower(v_email);

    if v_id is null then
      raise notice 'no public.users row for % (will still clear auth below)', v_email;
    else
      -- Money guard: refuse to delete while wallet holds funds.
      if coalesce((select balance from public.wallets where user_id = v_id), 0) > 0 then
        raise exception 'ABORT: % still has a positive wallet balance - withdraw it first', v_email;
      end if;

      -- Grandchildren that block the orders / user cascade (no ON DELETE CASCADE).
      delete from public.delivery_tracking dt
        using public.deliveries d
        where dt.delivery_id = d.id
          and (d.buyer_id = v_id or d.vendor_id = v_id
               or d.order_id in (select id from public.orders
                                 where buyer_id = v_id or vendor_id = v_id));
      delete from public.deliveries
        where buyer_id = v_id or vendor_id = v_id
           or order_id in (select id from public.orders
                           where buyer_id = v_id or vendor_id = v_id);
      delete from public.delivery_quotes
        where buyer_id = v_id or vendor_id = v_id
           or order_id in (select id from public.orders
                           where buyer_id = v_id or vendor_id = v_id);
      delete from public.vendor_charges
        where vendor_id = v_id
           or order_id in (select id from public.orders
                           where buyer_id = v_id or vendor_id = v_id);

      -- Direct user references without cascade.
      delete from public.disputes
        where buyer_id = v_id or vendor_id = v_id or admin_decided_by = v_id;
      delete from public.buyer_addresses     where buyer_id = v_id;
      delete from public.buyer_bank_accounts where buyer_id = v_id;
      delete from public.credit_transactions where buyer_id = v_id;
      delete from public.vendor_locations    where vendor_id = v_id;
      update public.state_change_requests set reviewed_by = null where reviewed_by = v_id;

      -- transactions.* are ON DELETE SET NULL, so they survive as anonymised
      -- financial records. Uncomment to hard-delete them instead:
      -- delete from public.transactions where buyer_id = v_id or vendor_id = v_id;

      -- Now the parent row: cascades stores -> products, orders, cart_items,
      -- chats/messages, device_tokens, wallets/wallet_transactions/withdrawals,
      -- withdrawal_pins, policy_acceptances, reviews, etc.
      delete from public.users where id = v_id;
      raise notice 'deleted public.users + cascade for %', v_email;
    end if;

    -- Remove the auth login so the email is free to register again.
    delete from auth.users where lower(email) = lower(v_email);
    raise notice 'cleared auth.users for %', v_email;
  end loop;
end $$;

-- Review the NOTICE output above. Then run ONE of:
--   COMMIT;    -- make the deletion permanent
--   ROLLBACK;  -- undo everything (safe if anything looked wrong)
