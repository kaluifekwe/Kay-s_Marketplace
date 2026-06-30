-- Contact/photo visibility rules:
--  * Avatars are public (shown across the app).
--  * A vendor sees a buyer's full contact (name/phone/address/photo) only for
--    buyers who ordered from them (scoped RPC) — not globally.
--  * A vendor's storefront phone (stores.phone) stays visible to buyers when the
--    vendor opts in (show_phone_to_buyers) — buyers can see/copy/call it on the
--    store page. The user's PERSONAL phone (users.phone) is dropped from the
--    public_profiles view (step 2, deferred until the new build is live) so it
--    is no longer globally harvestable.
-- Safe to re-run.

-- public_profiles: add avatar_url. NOTE: phone is kept here FOR NOW so older
-- app builds (which still select it) don't break mid-rollout. The new build no
-- longer reads phone from this view (vendor contact comes via the RPCs below).
-- Once the phone-free build is live for everyone, run step 2 at the bottom to
-- drop phone from the view.
CREATE OR REPLACE VIEW public_profiles AS
  SELECT id, name, phone, last_active, unique_id, avatar_url
  FROM users;
GRANT SELECT ON public_profiles TO anon, authenticated;

-- Vendor (or admin) gets a buyer's contact for one of THEIR orders.
CREATE OR REPLACE FUNCTION order_buyer_contact(p_order_id uuid)
RETURNS TABLE(name text, phone text, address text, unique_id text, avatar_url text) AS $$
  SELECT u.name, u.phone, u.address, u.unique_id, u.avatar_url
  FROM orders o
  JOIN users u ON u.id = o.buyer_id
  WHERE o.id = p_order_id
    AND (o.vendor_id = auth.uid()
         OR EXISTS (SELECT 1 FROM users a WHERE a.id = auth.uid() AND a.role = 'admin'));
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION order_buyer_contact(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION order_buyer_contact(uuid) TO authenticated, service_role;

-- ── Step 2 (deferred): run ONLY after the phone-free app build is live for all
-- users. Stops phone being globally harvestable via the view; vendor/dispute
-- screens already read buyer contact through order_buyer_contact() instead.
--
--   CREATE OR REPLACE VIEW public_profiles AS
--     SELECT id, name, last_active, unique_id, avatar_url
--     FROM users;
--   GRANT SELECT ON public_profiles TO anon, authenticated;
