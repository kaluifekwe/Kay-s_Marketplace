-- Performance indexes for 30K+ users with hundreds of thousands of products
-- Run this in Supabase SQL Editor

-- Products: paginated listing (most common query)
CREATE INDEX IF NOT EXISTS idx_products_created_at ON products(created_at DESC);

-- Products: category browsing
CREATE INDEX IF NOT EXISTS idx_products_category_created ON products(category, created_at DESC);

-- Products: search by name/description (GIN for ILIKE)
CREATE INDEX IF NOT EXISTS idx_products_name_gin ON products USING gin(name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_products_desc_gin ON products USING gin(description gin_trgm_ops);

-- Products: store lookup
CREATE INDEX IF NOT EXISTS idx_products_store_id ON products(store_id);

-- Orders: buyer orders (paginated)
CREATE INDEX IF NOT EXISTS idx_orders_buyer_created ON orders(buyer_id, created_at DESC);

-- Orders: vendor orders (paginated)
CREATE INDEX IF NOT EXISTS idx_orders_vendor_created ON orders(vendor_id, created_at DESC);

-- Orders: status filter
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);

-- Disputes: buyer disputes
CREATE INDEX IF NOT EXISTS idx_disputes_buyer_created ON disputes(buyer_id, created_at DESC);

-- Disputes: vendor disputes
CREATE INDEX IF NOT EXISTS idx_disputes_vendor_created ON disputes(vendor_id, created_at DESC);

-- Disputes: resolution deadline (for escalation cron)
CREATE INDEX IF NOT EXISTS idx_disputes_deadline ON disputes(resolution_deadline) WHERE status = 'open';

-- Chats: buyer chats
CREATE INDEX IF NOT EXISTS idx_chats_buyer ON chats(buyer_id);

-- Chats: vendor chats
CREATE INDEX IF NOT EXISTS idx_chats_vendor ON chats(vendor_id);

-- Chats: find existing chat between buyer+vendor
CREATE INDEX IF NOT EXISTS idx_chats_buyer_vendor ON chats(buyer_id, vendor_id);

-- Chats: lookup by order_id (used in openChat)
CREATE INDEX IF NOT EXISTS idx_chats_order_id ON chats(order_id);

-- Messages: chat messages (already have chat_id index, but add ordering)
CREATE INDEX IF NOT EXISTS idx_messages_chat_created ON messages(chat_id, created_at DESC);

-- Messages: unread count (covers neq sender + null read_at)
CREATE INDEX IF NOT EXISTS idx_messages_chat_read ON messages(chat_id, read_at) WHERE read_at IS NULL;

-- Messages: batch fetch for chat list (covers chat_id + sender + read_at)
CREATE INDEX IF NOT EXISTS idx_messages_chat_sender_read ON messages(chat_id, sender_id, read_at);

-- Reviews: store reviews
CREATE INDEX IF NOT EXISTS idx_reviews_store_created ON reviews(store_id, created_at DESC);

-- Reviews: check if user already reviewed
CREATE INDEX IF NOT EXISTS idx_reviews_order_user ON reviews(order_id, user_id);

-- Cart: buyer cart
CREATE INDEX IF NOT EXISTS idx_cart_buyer ON cart_items(buyer_id);

-- Users: last active (for online status)
CREATE INDEX IF NOT EXISTS idx_users_last_active ON users(last_active DESC);

-- Stores: vendor lookup
CREATE INDEX IF NOT EXISTS idx_stores_vendor ON stores(vendor_id);

-- Enable pg_trgm extension for search (run once)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- RPC: mark all unread messages in a chat as read (bypasses per-row RLS overhead)
CREATE OR REPLACE FUNCTION mark_chat_read(p_chat_id uuid, p_user_id uuid)
RETURNS void AS $$
  UPDATE messages
  SET read_at = now()
  WHERE chat_id = p_chat_id
    AND sender_id != p_user_id
    AND read_at IS NULL;
$$ LANGUAGE sql SECURITY DEFINER;

-- RPC: get chat list with unread counts and last messages in one call
CREATE OR REPLACE FUNCTION get_chat_list(p_user_id uuid, p_role text)
RETURNS TABLE (
  chat_id uuid,
  order_id text,
  buyer_id uuid,
  vendor_id uuid,
  created_at timestamptz,
  unread_count bigint,
  last_msg_id uuid,
  last_msg_content text,
  last_msg_type text,
  last_msg_sender_id uuid,
  last_msg_sender_role text,
  last_msg_created_at timestamptz
) AS $$
  WITH user_chats AS (
    SELECT c.id, c.order_id, c.buyer_id, c.vendor_id, c.created_at
    FROM chats c
    WHERE (p_role = 'buyer' AND c.buyer_id = p_user_id)
       OR (p_role = 'vendor' AND c.vendor_id = p_user_id)
  ),
  last_msgs AS (
    SELECT DISTINCT ON (m.chat_id)
      m.chat_id, m.id as last_msg_id, m.content as last_msg_content,
      m.type as last_msg_type, m.sender_id as last_msg_sender_id,
      m.sender_role as last_msg_sender_role, m.created_at as last_msg_created_at
    FROM messages m
    WHERE m.chat_id IN (SELECT id FROM user_chats)
    ORDER BY m.chat_id, m.created_at DESC
  ),
  unread AS (
    SELECT m.chat_id, COUNT(*) as unread_count
    FROM messages m
    WHERE m.chat_id IN (SELECT id FROM user_chats)
      AND m.sender_id != p_user_id
      AND m.read_at IS NULL
    GROUP BY m.chat_id
  )
  SELECT
    uc.id as chat_id, uc.order_id, uc.buyer_id, uc.vendor_id, uc.created_at,
    COALESCE(u.unread_count, 0) as unread_count,
    lm.last_msg_id, lm.last_msg_content, lm.last_msg_type,
    lm.last_msg_sender_id, lm.last_msg_sender_role, lm.last_msg_created_at
  FROM user_chats uc
  LEFT JOIN unread u ON u.chat_id = uc.id
  LEFT JOIN last_msgs lm ON lm.chat_id = uc.id
  ORDER BY u.unread_count DESC NULLS LAST, COALESCE(lm.last_msg_created_at, uc.created_at) DESC;
$$ LANGUAGE sql SECURITY DEFINER;
