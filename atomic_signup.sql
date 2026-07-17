-- Make signup atomic: a public.users profile can no longer be missing for an
-- auth.users row.
--
-- THE BUG THIS FIXES (diagnosed 2026-07-17): AuthService.register() did two
-- non-atomic steps — auth.signUp() (commits immediately) then
-- client.from('users').insert(). When the insert failed, the auth user was
-- already committed and became an ORPHAN. Because public.users has
-- users_email_key UNIQUE(email), one orphaned PROFILE row then blocked every
-- future signup on that email, and each retry minted another orphaned AUTH row.
-- The victim could not self-recover, and every flow reported a different lie:
--   signup  -> "email already exists"      (orphan profile holds the email)
--   reset   -> "Could not update password" (confirm-password-reset passes the
--              PROFILE id to auth.admin.updateUserById; that auth user is gone)
--   verify  -> "No active code"            (OTPs filed under the profile id, but
--              the session carries the auth id)
-- Only hand-written SQL on auth.users could rescue them. 2 orphans in 5 days on
-- a near-empty app.
--
-- THE FIX: create the profile in a trigger on auth.users INSERT, so both rows
-- land in ONE transaction. If the profile can't be created, the auth user is
-- rolled back too — signup fails cleanly instead of orphaning someone forever.
--
-- Pairs with the app change: register() now UPSERTs (not inserts) into users,
-- because this trigger has already created the row; the upsert enriches it with
-- phone/address/state/lga/unique_id. Ship both together.
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(nullif(new.raw_user_meta_data->>'role', ''), 'buyer');
  v_name text := coalesce(nullif(new.raw_user_meta_data->>'name', ''),
                          split_part(coalesce(new.email, 'user@unknown'), '@', 1));
BEGIN
  -- users_role_check only allows these; never let bad metadata abort a signup.
  IF v_role NOT IN ('buyer', 'vendor', 'rider', 'admin') THEN
    v_role := 'buyer';
  END IF;

  -- password is NOT NULL on public.users but is a dead column — Supabase Auth
  -- owns the real credential. Mirrors what register() has always written.
  INSERT INTO public.users (id, email, password, name, role)
  VALUES (new.id, new.email, 'managed_by_supabase_auth', v_name, v_role)
  ON CONFLICT (id) DO NOTHING;

  RETURN new;
END;
$$;

ALTER FUNCTION public.handle_new_auth_user() OWNER TO postgres;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- Verify:
--   select tgname from pg_trigger where tgrelid = 'auth.users'::regclass;
--
-- Find any remaining orphans (should stay empty forever after this):
--   select a.id, a.email, a.created_at from auth.users a
--   left join public.users u on u.id = a.id where u.id is null;
