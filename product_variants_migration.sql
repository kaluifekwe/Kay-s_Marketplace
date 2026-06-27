-- Run this in Supabase SQL Editor

-- Product variants table
CREATE TABLE IF NOT EXISTS product_variants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid REFERENCES products(id) ON DELETE CASCADE,
  label text NOT NULL,
  price numeric(12,2) NOT NULL,
  stock integer NOT NULL DEFAULT 0,
  image_url text,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

-- Enable RLS
ALTER TABLE product_variants ENABLE ROW LEVEL SECURITY;

-- RLS: anyone can read variants
CREATE POLICY "Anyone can view variants"
ON product_variants FOR SELECT
USING (true);

-- RLS: authenticated users (vendors) can insert/update/delete
CREATE POLICY "Authenticated can manage variants"
ON product_variants FOR ALL
WITH CHECK (auth.role() = 'authenticated');

-- Index for fast variant lookup
CREATE INDEX IF NOT EXISTS idx_variants_product ON product_variants(product_id, sort_order);

-- Add image_url column if table already exists
ALTER TABLE product_variants ADD COLUMN IF NOT EXISTS image_url text;

-- Storage bucket limits
UPDATE storage.buckets
SET
  file_size_limit = 2097152,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']
WHERE id = 'products' OR id = 'disputes' OR id = 'delivery';
