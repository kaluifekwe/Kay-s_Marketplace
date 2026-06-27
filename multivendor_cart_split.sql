-- Multi-vendor cart split order support
-- Run this in Supabase SQL Editor

-- Add payment_reference to link multiple orders from same checkout
ALTER TABLE orders ADD COLUMN IF NOT EXISTS payment_reference TEXT;

-- Index for fast lookups by payment reference
CREATE INDEX IF NOT EXISTS idx_orders_payment_reference ON orders(payment_reference);

-- Policy: anyone can read orders (existing)
-- No new policies needed — existing RLS handles this
