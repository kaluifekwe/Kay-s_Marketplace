-- Scalable chat read/delivery receipts.
--
-- Instead of stamping read_at on every message row (one realtime UPDATE per
-- message — heavy at 30k users), we keep ONE marker row per (chat, participant)
-- with last_read_at / last_delivered_at. Ticks are derived by comparing a
-- message's created_at against the OTHER participant's markers:
--   created_at <= other.last_read_at       -> read   (✓✓ blue)
--   created_at <= other.last_delivered_at  -> delivered (✓✓)
--   otherwise (persisted)                   -> sent   (✓)
-- Marking read/delivered is then a single upsert, not N updates.
-- Safe to run multiple times.

CREATE TABLE IF NOT EXISTS chat_members (
  chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  last_read_at TIMESTAMPTZ,
  last_delivered_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (chat_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_chat_members_chat ON chat_members(chat_id);

ALTER TABLE chat_members ENABLE ROW LEVEL SECURITY;

-- Either participant of a chat can READ both marker rows for that chat, so the
-- sender can see the recipient's read/delivered markers to render ticks.
DROP POLICY IF EXISTS chat_members_participant_read ON chat_members;
CREATE POLICY chat_members_participant_read ON chat_members
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM chats c
      WHERE c.id = chat_members.chat_id
        AND (c.buyer_id = auth.uid() OR c.vendor_id = auth.uid())
    )
  );

-- A user may only write their OWN marker row (and only for a chat they're in).
DROP POLICY IF EXISTS chat_members_self_insert ON chat_members;
CREATE POLICY chat_members_self_insert ON chat_members
  FOR INSERT WITH CHECK (
    user_id = auth.uid() AND EXISTS (
      SELECT 1 FROM chats c
      WHERE c.id = chat_members.chat_id
        AND (c.buyer_id = auth.uid() OR c.vendor_id = auth.uid())
    )
  );

DROP POLICY IF EXISTS chat_members_self_update ON chat_members;
CREATE POLICY chat_members_self_update ON chat_members
  FOR UPDATE USING (user_id = auth.uid());

-- Stamp the caller's marker for a chat to now(). kind = 'read' | 'delivered'.
-- 'read' implies 'delivered'. SECURITY DEFINER so a single call works without
-- tripping per-row RLS, but it always acts on auth.uid() — never another user.
CREATE OR REPLACE FUNCTION touch_chat_member(p_chat_id uuid, p_kind text)
RETURNS void AS $$
  INSERT INTO chat_members (chat_id, user_id, last_read_at, last_delivered_at, updated_at)
  VALUES (
    p_chat_id,
    auth.uid(),
    CASE WHEN p_kind = 'read' THEN now() ELSE NULL END,
    now(),
    now()
  )
  ON CONFLICT (chat_id, user_id) DO UPDATE SET
    last_delivered_at = now(),
    last_read_at = CASE WHEN p_kind = 'read' THEN now() ELSE chat_members.last_read_at END,
    updated_at = now();
$$ LANGUAGE sql SECURITY DEFINER;

-- Realtime so the sender gets the recipient's marker updates live (only 2 rows
-- per chat, so this is cheap — unlike per-message read_at updates).
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE chat_members;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
