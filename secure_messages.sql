-- Lock down message edits. The "Messages update" policy lets any chat
-- participant UPDATE any message row in that chat — including editing the OTHER
-- person's message content, sender, or the delivery-fee amounts. The only
-- legitimate client updates are accepting/declining a delivery fee
-- (delivery_fee_status) and marking read (read_at). This trigger blocks every
-- other column change for non-service/non-admin callers. Safe to re-run.

CREATE OR REPLACE FUNCTION guard_message_columns()
RETURNS trigger AS $$
BEGIN
  IF auth.role() = 'service_role'
     OR EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  THEN
    RETURN NEW;
  END IF;

  IF NEW.chat_id             IS DISTINCT FROM OLD.chat_id
     OR NEW.sender_id           IS DISTINCT FROM OLD.sender_id
     OR NEW.sender_role         IS DISTINCT FROM OLD.sender_role
     OR NEW.content            IS DISTINCT FROM OLD.content
     OR NEW.type               IS DISTINCT FROM OLD.type
     OR NEW.reply_to_id         IS DISTINCT FROM OLD.reply_to_id
     OR NEW.reply_to_content    IS DISTINCT FROM OLD.reply_to_content
     OR NEW.reply_to_sender     IS DISTINCT FROM OLD.reply_to_sender
     OR NEW.created_at          IS DISTINCT FROM OLD.created_at
     OR NEW.delivery_fee_amount IS DISTINCT FROM OLD.delivery_fee_amount
     OR NEW.vendor_contribution IS DISTINCT FROM OLD.vendor_contribution
     OR NEW.buyer_fee_amount    IS DISTINCT FROM OLD.buyer_fee_amount
  THEN
    RAISE EXCEPTION 'Only delivery_fee_status / read_at may be updated on a message';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_guard_message_columns ON messages;
CREATE TRIGGER trg_guard_message_columns
  BEFORE UPDATE ON messages
  FOR EACH ROW EXECUTE FUNCTION guard_message_columns();
