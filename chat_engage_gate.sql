-- A buyer may only ENGAGE a vendor (start a chat) when they are KYC-verified
-- AND in the same state. Same rule as buying; cross-state / unverified buyers
-- can view but not chat. Enforced server-side on chat creation so a modified
-- client can't bypass. (Existing chats are unaffected; messages flow within a
-- chat that was created when allowed.) Safe to re-run.

CREATE OR REPLACE FUNCTION buyer_can_engage(p_vendor_id uuid)
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1
    FROM users b
    JOIN users v ON v.id = p_vendor_id
    WHERE b.id = auth.uid()
      AND b.kyc_status = 'verified'
      AND b.state IS NOT NULL
      AND b.state = v.state
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION buyer_can_engage(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION buyer_can_engage(uuid) TO authenticated, service_role;

-- Tighten chat creation: the vendor may create; a buyer may create only if
-- verified + same state.
DROP POLICY IF EXISTS "Chats insert" ON chats;
CREATE POLICY "Chats insert" ON chats
  FOR INSERT
  WITH CHECK (
    auth.uid() = vendor_id
    OR (auth.uid() = buyer_id AND buyer_can_engage(vendor_id))
  );
