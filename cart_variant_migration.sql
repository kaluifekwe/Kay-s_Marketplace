-- Add variant support to cart_items table
-- Run this in Supabase SQL Editor

ALTER TABLE cart_items
  ADD COLUMN IF NOT EXISTS variant_label text,
  ADD COLUMN IF NOT EXISTS variant_price numeric(12,2);
