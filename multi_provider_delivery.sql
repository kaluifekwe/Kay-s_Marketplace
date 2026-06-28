-- Multi-provider delivery support (Shipbubble + Terminal Africa + future).
-- Adds the columns the refactored get-delivery-quotes / book-delivery write.
-- Safe to run multiple times.

-- delivery_quotes: per-provider opaque blobs (address codes / ids, tokens).
-- available_couriers now stores the MERGED list { couriers, sender, receiver, items }.
ALTER TABLE delivery_quotes
  ADD COLUMN IF NOT EXISTS provider_data JSONB;

-- deliveries: which provider booked it, and that provider's order id.
-- shipbubble_order_id is kept populated for back-compat with existing rows/webhook.
ALTER TABLE deliveries
  ADD COLUMN IF NOT EXISTS provider TEXT DEFAULT 'shipbubble',
  ADD COLUMN IF NOT EXISTS provider_order_id TEXT;

-- Backfill provider_order_id for any existing Shipbubble deliveries.
UPDATE deliveries
  SET provider_order_id = shipbubble_order_id
  WHERE provider_order_id IS NULL AND shipbubble_order_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_deliveries_provider_order ON deliveries(provider_order_id);
