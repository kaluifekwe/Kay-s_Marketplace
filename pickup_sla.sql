-- Pickup SLA: courier orders the vendor never books are reminded, then
-- auto-cancelled + refunded. Safe to run multiple times.

-- Deadline by which the vendor must tap "Request Pickup" (set by
-- paystack-webhook = paid_at + window). pickup_reminded guards the one-time
-- reminder so the cron doesn't spam.
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS pickup_deadline TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS pickup_reminded BOOLEAN DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_orders_pickup_deadline
  ON orders(pickup_deadline)
  WHERE pickup_deadline IS NOT NULL;

-- Widen the order status constraint. The original list omitted 'cancelled'
-- and 'refund_processing', which silently broke buyer cancelOrder AND
-- process-refund (their status updates violated the check). Include every
-- status the app actually uses.
ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_status_check;
ALTER TABLE orders ADD CONSTRAINT orders_status_check CHECK (
  status IN (
    'paid', 'shipped', 'delivered', 'confirmed',
    'in_transit', 'courier_booked',
    'refund_requested', 'refund_processing', 'refunded',
    'auto_released', 'cancelled'
  )
);
