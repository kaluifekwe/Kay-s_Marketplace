-- Feature 1: Flexible chat-based delivery fee
ALTER TABLE products
  ADD COLUMN IF NOT EXISTS delivery_type TEXT DEFAULT 'negotiate';
  -- 'free' | 'negotiate' | 'split'

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS delivery_type TEXT,
  ADD COLUMN IF NOT EXISTS delivery_fee DECIMAL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS vendor_delivery_contribution DECIMAL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_with_delivery DECIMAL;

-- messages.type already exists with a CHECK constraint limited to
-- text/image/video/product_card. Widen it to include the two new
-- delivery-request message types instead of adding a redundant column.
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_type_check
  CHECK (type IN ('text', 'image', 'video', 'product_card', 'delivery_fee_request', 'delivery_split_request'));

ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS delivery_fee_amount DECIMAL,
  ADD COLUMN IF NOT EXISTS vendor_contribution DECIMAL,
  ADD COLUMN IF NOT EXISTS buyer_fee_amount DECIMAL,
  ADD COLUMN IF NOT EXISTS delivery_fee_status TEXT;
  -- pending | accepted | declined | superseded

-- Feature 2: Vendor store profile
-- stores already has phone/description/created_at — reuse those instead
-- of adding duplicate columns. Add only the genuinely new fields.
ALTER TABLE stores
  ADD COLUMN IF NOT EXISTS whatsapp_number TEXT,
  ADD COLUMN IF NOT EXISTS show_phone_to_buyers BOOLEAN DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS store_banner_url TEXT,
  ADD COLUMN IF NOT EXISTS response_time TEXT,
  ADD COLUMN IF NOT EXISTS is_verified BOOLEAN DEFAULT FALSE;
  -- response_time: 'usually_fast' | 'within_hours' | 'within_day'
