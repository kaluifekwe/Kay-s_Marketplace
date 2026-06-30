-- Stop notification phishing. The old policy let ANY authenticated user insert
-- a notification for ANY user_id with arbitrary text ("Your account is
-- suspended — tap here"). Scope client inserts to self or a genuine
-- counterparty (someone you share a chat or order with). Server-created
-- notifications (Edge Functions, service role) bypass RLS and are unaffected;
-- admins may notify anyone. Safe to re-run.

DROP POLICY IF EXISTS "Authenticated insert notifications" ON notifications;

CREATE POLICY "Insert notifications for self or counterparties" ON notifications
  FOR INSERT WITH CHECK (
    auth.uid() = user_id
    OR is_admin()
    OR EXISTS (
      SELECT 1 FROM chats c
      WHERE (c.buyer_id = auth.uid()  AND c.vendor_id = notifications.user_id)
         OR (c.vendor_id = auth.uid() AND c.buyer_id  = notifications.user_id)
    )
    OR EXISTS (
      SELECT 1 FROM orders o
      WHERE (o.buyer_id = auth.uid()  AND o.vendor_id = notifications.user_id)
         OR (o.vendor_id = auth.uid() AND o.buyer_id  = notifications.user_id)
    )
  );
