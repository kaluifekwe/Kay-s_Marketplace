-- Reusable RLS/authorization primitives. Compose these in policies and
-- SECURITY DEFINER functions instead of re-writing EXISTS(...) each time, so
-- every feature applies the SAME access rules. All are SECURITY DEFINER + STABLE
-- so they read the row they check without tripping the caller's RLS (and avoid
-- policy recursion). Safe to re-run.

-- Caller is an admin.
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean AS $$
  SELECT EXISTS (SELECT 1 FROM users WHERE id = auth.uid() AND role = 'admin');
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- Caller is the buyer or vendor on this chat.
CREATE OR REPLACE FUNCTION is_chat_participant(p_chat_id uuid)
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM chats c
    WHERE c.id = p_chat_id
      AND (c.buyer_id = auth.uid() OR c.vendor_id = auth.uid())
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- Caller is the buyer or vendor on this order.
CREATE OR REPLACE FUNCTION is_order_party(p_order_id uuid)
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM orders o
    WHERE o.id = p_order_id
      AND (o.buyer_id = auth.uid() OR o.vendor_id = auth.uid())
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- Caller owns this store.
CREATE OR REPLACE FUNCTION is_store_owner(p_store_id uuid)
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM stores s
    WHERE s.id = p_store_id AND s.vendor_id = auth.uid()
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION is_admin(), is_chat_participant(uuid), is_order_party(uuid), is_store_owner(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION is_admin(), is_chat_participant(uuid), is_order_party(uuid), is_store_owner(uuid) TO authenticated, service_role;

-- Usage in a new table's policies, e.g.:
--   ALTER TABLE foo ENABLE ROW LEVEL SECURITY;
--   CREATE POLICY foo_party_read ON foo FOR SELECT USING (is_order_party(order_id));
--   CREATE POLICY foo_admin_all  ON foo FOR ALL    USING (is_admin());
