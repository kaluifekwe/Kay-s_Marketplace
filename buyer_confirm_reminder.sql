-- Buyer delivery-confirmation reminders. Tracks when we last nudged the buyer
-- to confirm receipt during the 24h window, so auto-release-escrow can remind
-- them roughly every 6 hours (mirrors the vendor return-confirmation reminder).
-- Safe to re-run.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS confirm_last_reminder_at timestamptz;

NOTIFY pgrst, 'reload schema';
