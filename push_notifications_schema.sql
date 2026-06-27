-- DispatchPH Push Notifications Schema
-- Run this in Supabase SQL Editor

-- Device tokens table for FCM push notifications
CREATE TABLE IF NOT EXISTS device_tokens (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  fcm_token TEXT NOT NULL,
  platform TEXT DEFAULT 'android',
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, platform)
);

-- RLS policies
ALTER TABLE device_tokens ENABLE ROW LEVEL SECURITY;

-- Users can insert/update their own tokens
CREATE POLICY "Users can manage own device tokens"
  ON device_tokens FOR ALL
  USING (auth.uid() = user_id);

-- Service role can read all tokens (for Edge Function)
CREATE POLICY "Service role can read all tokens"
  ON device_tokens FOR SELECT
  USING (true);

-- Index for fast token lookups by user_id
CREATE INDEX IF NOT EXISTS idx_device_tokens_user_id ON device_tokens(user_id);
