-- 1. Add missing orders columns
ALTER TABLE orders ADD COLUMN IF NOT EXISTS delivery_method text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS rider_name text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS rider_phone text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS shipping_proof_url text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS delivery_photo_url text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS payment_released boolean DEFAULT false;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS shipped_at timestamptz;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS confirmed_at timestamptz;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS auto_release_at timestamptz;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS delivery_confirmed_at timestamptz;

-- 2. Create storage buckets
INSERT INTO storage.buckets (id, name, public) VALUES ('products', 'products', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.buckets (id, name, public) VALUES ('disputes', 'disputes', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.buckets (id, name, public) VALUES ('delivery', 'delivery', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('chat_media', 'chat_media', true, 10485760,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'video/mp4'])
ON CONFLICT (id) DO NOTHING;

-- 3. Storage RLS policies (drop first to avoid duplicates)
DROP POLICY IF EXISTS "Public read access for products bucket" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated insert for products bucket" ON storage.objects;
DROP POLICY IF EXISTS "Public read access for disputes bucket" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated insert for disputes bucket" ON storage.objects;
DROP POLICY IF EXISTS "Public read access for delivery bucket" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated insert for delivery bucket" ON storage.objects;
DROP POLICY IF EXISTS "Public read access for chat_media bucket" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated insert for chat_media bucket" ON storage.objects;

CREATE POLICY "Public read access for products bucket"
ON storage.objects FOR SELECT
USING (bucket_id = 'products');

CREATE POLICY "Authenticated insert for products bucket"
ON storage.objects FOR INSERT
WITH CHECK (bucket_id = 'products' AND auth.role() = 'authenticated');

CREATE POLICY "Public read access for disputes bucket"
ON storage.objects FOR SELECT
USING (bucket_id = 'disputes');

CREATE POLICY "Authenticated insert for disputes bucket"
ON storage.objects FOR INSERT
WITH CHECK (bucket_id = 'disputes' AND auth.role() = 'authenticated');

CREATE POLICY "Public read access for delivery bucket"
ON storage.objects FOR SELECT
USING (bucket_id = 'delivery');

CREATE POLICY "Authenticated insert for delivery bucket"
ON storage.objects FOR INSERT
WITH CHECK (bucket_id = 'delivery' AND auth.role() = 'authenticated');

CREATE POLICY "Public read access for chat_media bucket"
ON storage.objects FOR SELECT
USING (bucket_id = 'chat_media');

CREATE POLICY "Authenticated insert for chat_media bucket"
ON storage.objects FOR INSERT
WITH CHECK (bucket_id = 'chat_media' AND auth.role() = 'authenticated');
