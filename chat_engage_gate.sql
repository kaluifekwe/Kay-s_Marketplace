-- A buyer may ENGAGE a vendor (start a chat) when they are in the SAME STATE.
-- No KYC: buyer KYC was removed from the product (2026-07-17) — buyers browse,
-- chat and buy freely; only VENDORS need KYC, and a buyer only needs a NIN to
-- WITHDRAW money (e.g. a refund). Same-state stays because the marketplace is
-- intrastate, so a cross-state chat could never become an order. Enforced
-- server-side on chat creation so a modified client can't bypass. (Existing
-- chats are unaffected; messages flow within a chat created when allowed.)
-- Safe to re-run.
--
-- HISTORY: this gate previously also required kyc_status='verified'. It was
-- applied to the live DB and never reverted when buyer KYC was dropped, so every
-- buyer (all of whom have kyc_status='none') was silently blocked from starting a
-- chat — the app only said "Chat not loaded. Please go back and reopen." Vendors
-- were unaffected (they match the policy's first branch), which is why it went
-- unnoticed. Don't reintroduce a KYC clause here.

CREATE OR REPLACE FUNCTION buyer_can_engage(p_vendor_id uuid)
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1
    FROM users b
    JOIN users v ON v.id = p_vendor_id
    WHERE b.id = auth.uid()
      AND b.state IS NOT NULL
      AND b.state = v.state
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION buyer_can_engage(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION buyer_can_engage(uuid) TO authenticated, service_role;

-- Chat creation: the vendor may always create; a buyer may create only in-state.
DROP POLICY IF EXISTS "Chats insert" ON chats;
CREATE POLICY "Chats insert" ON chats
  FOR INSERT
  WITH CHECK (
    auth.uid() = vendor_id
    OR (auth.uid() = buyer_id AND buyer_can_engage(vendor_id))
  );

-- Verify (KYC clause gone, same-state kept):
--   select pg_get_functiondef(oid) from pg_proc where proname = 'buyer_can_engage';
