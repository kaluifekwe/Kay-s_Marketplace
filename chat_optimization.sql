-- Chat performance: new indexes + RPC functions
-- Run this in Supabase SQL Editor

-- chats lookup by order_id (used in openChat)
CREATE INDEX IF NOT EXISTS idx_chats_order_id ON chats(order_id);

-- messages composite index for batch chat list queries
CREATE INDEX IF NOT EXISTS idx_messages_chat_sender_read ON messages(chat_id, sender_id, read_at);

-- RPC: mark all unread messages in a chat as read (bypasses per-row RLS)
CREATE OR REPLACE FUNCTION mark_chat_read(p_chat_id uuid, p_user_id uuid)
RETURNS void AS $$
  UPDATE messages
  SET read_at = now()
  WHERE chat_id = p_chat_id
    AND sender_id != p_user_id
    AND read_at IS NULL;
$$ LANGUAGE sql SECURITY DEFINER;

-- Chat media storage bucket (run via Dashboard if anon key lacks permission)
-- Go to: Supabase Dashboard > Storage > New Bucket
-- Name: chat_media
-- Public: yes
-- File size limit: 10MB
-- Allowed MIME types: image/jpeg, image/png, image/webp, video/mp4
