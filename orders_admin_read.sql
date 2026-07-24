-- Let admin accounts read every order.
--
-- The web admin console (dispatch-admin) reads via the PUBLIC anon key, so RLS
-- decides what it can see. The orders table only had buyer/vendor read policies
-- ("Orders buyer read": auth.uid() = buyer_id, "Orders vendor read":
-- auth.uid() = vendor_id), so an admin — who is neither the buyer nor the vendor
-- of most orders — got ZERO rows. The order detail page rendered every field
-- blank and the Refund button never appeared.
--
-- Read-only and admin-gated. Writes (refund, release) still go through edge
-- functions using the service-role key, which bypass RLS, so no admin UPDATE
-- policy is added here.
DROP POLICY IF EXISTS "Orders admin read" ON public.orders;
CREATE POLICY "Orders admin read" ON public.orders
  FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.users u
                 WHERE u.id = auth.uid() AND u.role = 'admin'));
