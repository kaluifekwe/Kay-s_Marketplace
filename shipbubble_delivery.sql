-- Shipbubble courier integration for Kay's Marketplace.
--
-- Reconciliation notes (differ from the original spec on purpose):
--   * All FKs reference users(id) — this codebase has NO profiles table.
--   * No dispute_deadline is (re)introduced. Courier orders extend the
--     existing auto_release_at = delivered + 24h in the shipbubble-webhook;
--     manually-shipped / chat-fallback orders keep their ship-time window.
--   * Shipbubble is the default delivery path; when no courier covers a
--     route, checkout falls back to the existing in-chat negotiate flow
--     (delivery_fee_vendor_profile.sql).

-- ---- Vendor pickup locations ----
CREATE TABLE IF NOT EXISTS vendor_locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID REFERENCES users(id) NOT NULL,
  label TEXT NOT NULL,                 -- "Main Shop", "Warehouse", "Home"
  address TEXT NOT NULL,
  landmark TEXT NOT NULL,              -- required for NG addresses
  city TEXT NOT NULL,                  -- Lagos | Abuja | Port Harcourt
  state TEXT NOT NULL,
  latitude DECIMAL,
  longitude DECIMAL,
  is_default BOOLEAN DEFAULT FALSE,
  is_verified BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_vendor_locations_vendor ON vendor_locations(vendor_id);

-- ---- Buyer delivery addresses ----
CREATE TABLE IF NOT EXISTS buyer_addresses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  buyer_id UUID REFERENCES users(id) NOT NULL,
  label TEXT NOT NULL,                 -- "Home", "Office", "Mum's Place"
  address TEXT NOT NULL,
  landmark TEXT NOT NULL,              -- required for NG addresses
  city TEXT NOT NULL,
  state TEXT NOT NULL,
  latitude DECIMAL,
  longitude DECIMAL,
  is_default BOOLEAN DEFAULT FALSE,
  is_verified BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_buyer_addresses_buyer ON buyer_addresses(buyer_id);

-- ---- Delivery rate quotes (short-lived; keyed by buyer+vendor+cart, NOT order_id) ----
-- Orders don't exist until after payment (paystack-webhook), so quotes are
-- fetched at checkout before any order row exists. order_id stays null until
-- the webhook back-fills it when the order is created.
CREATE TABLE IF NOT EXISTS delivery_quotes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES orders(id),
  vendor_id UUID REFERENCES users(id),
  buyer_id UUID REFERENCES users(id),
  pickup_address TEXT NOT NULL,
  pickup_landmark TEXT,
  pickup_city TEXT,
  pickup_latitude DECIMAL,
  pickup_longitude DECIMAL,
  delivery_address TEXT NOT NULL,
  delivery_landmark TEXT,
  delivery_city TEXT,
  delivery_latitude DECIMAL,
  delivery_longitude DECIMAL,
  item_weight DECIMAL NOT NULL,
  -- Shipbubble address codes returned by validate-address, needed at booking.
  sender_address_code TEXT,
  receiver_address_code TEXT,
  package_items JSONB,
  available_couriers JSONB,            -- full Shipbubble rates response
  selected_courier_name TEXT,
  selected_service_code TEXT,
  selected_courier_id TEXT,
  selected_fee DECIMAL,
  expires_at TIMESTAMPTZ,              -- 15 minutes from creation
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_delivery_quotes_buyer ON delivery_quotes(buyer_id);

-- ---- Delivery bookings ----
CREATE TABLE IF NOT EXISTS deliveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES orders(id) NOT NULL,
  vendor_id UUID REFERENCES users(id) NOT NULL,
  buyer_id UUID REFERENCES users(id) NOT NULL,

  -- Shipbubble details
  shipbubble_order_id TEXT,
  courier_name TEXT,
  courier_phone TEXT,
  courier_email TEXT,
  tracking_code TEXT,
  tracking_url TEXT,

  -- Addresses used for this delivery
  pickup_address TEXT NOT NULL,
  pickup_landmark TEXT,
  pickup_city TEXT NOT NULL,
  pickup_latitude DECIMAL,
  pickup_longitude DECIMAL,
  delivery_address TEXT NOT NULL,
  delivery_landmark TEXT,
  delivery_city TEXT NOT NULL,
  delivery_latitude DECIMAL,
  delivery_longitude DECIMAL,
  delivery_note TEXT,

  -- Item details
  item_name TEXT NOT NULL,
  item_description TEXT,
  item_weight DECIMAL NOT NULL,
  item_quantity INT DEFAULT 1,
  item_amount DECIMAL NOT NULL,

  -- Pricing
  shipbubble_fee DECIMAL NOT NULL,     -- what Shipbubble charges us
  kays_markup DECIMAL DEFAULT 0,
  buyer_charged DECIMAL NOT NULL,      -- shipbubble_fee + kays_markup

  status TEXT DEFAULT 'pending',       -- pending|confirmed|picked_up|in_transit|delivered|failed|cancelled

  booked_at TIMESTAMPTZ DEFAULT NOW(),
  confirmed_at TIMESTAMPTZ,
  picked_up_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  estimated_delivery TEXT,

  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_deliveries_order ON deliveries(order_id);
CREATE INDEX IF NOT EXISTS idx_deliveries_shipbubble_order ON deliveries(shipbubble_order_id);

-- ---- Delivery tracking events ----
CREATE TABLE IF NOT EXISTS delivery_tracking (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id UUID REFERENCES deliveries(id),
  status TEXT NOT NULL,
  description TEXT,
  location TEXT,
  timestamp TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_delivery_tracking_delivery ON delivery_tracking(delivery_id);

-- ---- Shipbubble wallet balance (single row, cached from Shipbubble billing API) ----
CREATE TABLE IF NOT EXISTS shipbubble_wallet (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  balance DECIMAL DEFAULT 0,
  low_balance_threshold DECIMAL DEFAULT 50000,
  last_checked_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ---- Orders: courier delivery linkage ----
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS has_shipbubble_delivery BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS delivery_quote_id UUID,
  ADD COLUMN IF NOT EXISTS delivery_id UUID;

-- ---- RLS ----
ALTER TABLE vendor_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE buyer_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE delivery_quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE delivery_tracking ENABLE ROW LEVEL SECURITY;

-- Vendors manage their own pickup locations.
DROP POLICY IF EXISTS vendor_locations_owner ON vendor_locations;
CREATE POLICY vendor_locations_owner ON vendor_locations
  FOR ALL USING (auth.uid() = vendor_id) WITH CHECK (auth.uid() = vendor_id);

-- Buyers manage their own addresses.
DROP POLICY IF EXISTS buyer_addresses_owner ON buyer_addresses;
CREATE POLICY buyer_addresses_owner ON buyer_addresses
  FOR ALL USING (auth.uid() = buyer_id) WITH CHECK (auth.uid() = buyer_id);

-- Either party to a delivery can read it. Writes happen via service role only.
DROP POLICY IF EXISTS deliveries_party_read ON deliveries;
CREATE POLICY deliveries_party_read ON deliveries
  FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = vendor_id);

-- Buyer who requested a quote can read it back.
DROP POLICY IF EXISTS delivery_quotes_owner ON delivery_quotes;
CREATE POLICY delivery_quotes_owner ON delivery_quotes
  FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = vendor_id);

-- Tracking readable by either party to the parent delivery.
DROP POLICY IF EXISTS delivery_tracking_party_read ON delivery_tracking;
CREATE POLICY delivery_tracking_party_read ON delivery_tracking
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM deliveries d
      WHERE d.id = delivery_tracking.delivery_id
        AND (d.buyer_id = auth.uid() OR d.vendor_id = auth.uid())
    )
  );

-- Seed the single wallet row if missing.
INSERT INTO shipbubble_wallet (balance, low_balance_threshold)
SELECT 0, 50000
WHERE NOT EXISTS (SELECT 1 FROM shipbubble_wallet);
