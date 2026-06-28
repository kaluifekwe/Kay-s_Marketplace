-- Request Pickup: book the courier when the vendor is ready, not at payment.
-- Safe to run multiple times.

-- Persist the buyer's courier choice on the order so request-pickup can book it
-- later (the original delivery_quotes row still holds addresses + items for the
-- re-quote, so no address columns are needed here).
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS selected_courier_name TEXT,
  ADD COLUMN IF NOT EXISTS selected_provider TEXT;

-- Idempotency / race safety: at most ONE active delivery per order, so a
-- double-tap or a retried request can never double-book or double-charge the
-- wallet. A failed/cancelled delivery is excluded, so an order CAN be re-booked
-- after a courier falls through.
--
-- Clean up any pre-existing active duplicates first (keep the most recent),
-- otherwise the unique index can't be created. (Pre-launch test data only.)
WITH ranked AS (
  SELECT id,
         row_number() OVER (PARTITION BY order_id ORDER BY created_at DESC) AS rn
  FROM deliveries
  WHERE status NOT IN ('cancelled', 'failed')
)
DELETE FROM deliveries d
USING ranked r
WHERE d.id = r.id AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_active_delivery_per_order
  ON deliveries(order_id)
  WHERE status NOT IN ('cancelled', 'failed');
