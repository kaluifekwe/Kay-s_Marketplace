# Kay's Marketplace — Pre-Launch Checklist

Everything that must be done before publishing to the Google Play Store (and
later the App Store). Keep this updated as we build. Group order ≈ the order
we'll tackle them.

Legend: ⬜ todo · 🟡 in progress · ✅ done

---

## 1. Domain & web

- ⬜ **Buy a domain** (e.g. `kaysmarketplace.com`). Needed for share links, deep
  links, privacy-policy URL, and the Play Store listing website field.
- ⬜ **Host the share/product page on Vercel** and point the domain at it.
  - Interim: the product share page runs as the Supabase Edge Function
    `share-product`. Once the domain + Vercel page exist, set the app's
    `SHARE_BASE_URL` to the real domain so links read
    `https://yourdomain/p/<id>` instead of the Supabase URL.
- ⬜ **Publish a public Privacy Policy + Terms page** on the domain (Play Store
  requires a privacy-policy URL). We already have the in-app agreement
  (`docs/policy.md`); a hosted web copy is also needed.

## 2. Payments & money (Paystack / escrow)

- ⬜ Switch Paystack to **live keys** (currently test/sim). Update Supabase
  secrets and any `.env`.
- ⬜ Verify escrow auto-release, refunds, and payouts against **live** Paystack.
- ⬜ Confirm webhook signature verification is on for the live Paystack webhook.
- ⬜ **Apply `transfer_reconciliation.sql`** (adds `orders.payout_status` /
  `payout_attempts`). MUST run before deploying the updated `release-escrow` /
  `paystack-webhook`, or releases error on the missing columns.
- ⬜ In the Paystack dashboard, **enable Transfer events** on the webhook (same
  URL as charge events) so payout success/failure reconcile. (Code: payouts are
  marked `processing` on initiation and confirmed `paid`/`failed` by the
  `transfer.success`/`transfer.failed`/`transfer.reversed` webhook.)
- ⬜ **Disable OTP on transfers** (Paystack → Settings → Transfers) so automated
  payouts don't stall waiting for approval; confirm transfer **limits/KYC** are
  raised for expected volume.
- ⬜ Ensure Paystack **settlement** funds the transfer balance in time (instant
  settlement or keep a float buffer) — payouts use `source: balance`.
- ⬜ Work the **payout-attention queue** before launch dry-run: orders with
  `payout_status IN ('failed','pending_bank')` need retry / vendor bank fix.
- ⬜ **Card chargebacks:** consider a longer hold or a small rolling reserve —
  a card payment can be charged back after the vendor has been paid.
- ⬜ **Confirm `pg_cron` is actually scheduled in prod** (auto-release +
  pickup-SLA). Add a heartbeat/alert if it stops — if it silently dies, nothing
  auto-releases and vendors go unpaid.

## 3. Delivery providers (Shipbubble + Terminal)

- ⬜ **Fund the live Shipbubble wallet** (empty wallet → address validation
  fails → no couriers → negotiate fallback).
- ⬜ Register the Shipbubble webhook URL:
  `https://takuhbkpagvhmxsncdls.supabase.co/functions/v1/shipbubble-webhook`.
- ⬜ **Fund the Terminal wallet**; set `TERMINAL_BASE_URL` to production + live
  key.
- ⬜ Register the Terminal webhook URL:
  `https://takuhbkpagvhmxsncdls.supabase.co/functions/v1/terminal-webhook`
  (set `TERMINAL_WEBHOOK_SECRET`).

## 4. Policy / legal

- ✅ Policy-acceptance gate built (buyers + vendors sign before using the app).
- ✅ `policy_acceptance.sql` applied to Supabase (`takuhbkpagvhmxsncdls`).
- ⬜ Fill the real effective date in `docs/policy.md` / `app_policy.dart`.
- ⬜ Decide whether to name a legal entity + support contact in the policy.

## 5. Product & store sharing

- ✅ In-app **Share** button on products (native share sheet).
- ✅ **`share-product` Edge Function** (public Open Graph page) — deployed +
  verified live (verify_jwt=false).
- ✅ **`share-store` Edge Function** (public storefront: all of a vendor's
  listings, "buy in app") — deployed + verified live.
- ✅ In-app **"Share My Store"** action on the vendor dashboard + store `handle`
  (clean slug) auto-generated at registration.
- ⬜ **Apply `store_handle.sql`** to Supabase (`takuhbkpagvhmxsncdls`) — adds the
  `stores.handle` column + backfills existing stores. REQUIRED before the new
  app build (registration writes `handle`) and before handle-based store links
  work.
- ⬜ Set `APP_PLAY_STORE_URL` (and `APP_STORE_URL`) secrets so the "Get the app"
  button links to the real store listings (shows "coming soon" until set).
- ⬜ Phase 2: when the Next.js site exists, set `SHARE_BASE_URL` to the domain —
  share links become `/p/<id>` and `/store/<handle>`, and the two share-* edge
  functions become redundant.

## 6. Storage & security

Security review done 2026-06-30. Frontend clean (only the public anon key is
bundled); RLS is on for every table; `security_fixes_critical.sql` is applied.
Fixes from the review:
- ✅ **Price tampering** — `create-payment` now derives item prices from the DB
  (was trusting the client `subtotal` → pay ₦1 for anything). Deployed.
- ⬜ **Apply `harden_rls.sql`** — BEFORE UPDATE triggers stop clients writing
  privileged columns: `users.role/kays_credit/dispute_flags/payout_blocked` +
  the intrastate **state lock**, and `orders` money/release fields + only the
  buyer/service can change `has_dispute`. (Closes admin/credit escalation +
  payout tampering.) Test dispute + state-change flows after applying.
- ⬜ **PII exposure** — `users` "read others = true" exposes every column
  (email, phone, NIN, kays_credit, role) to any logged-in user. Replace with a
  `public_profiles` view (id, name, unique_id) and repoint name lookups. (App
  change — pending.)
- ⬜ **Notifications** — `notifications` insert is open to any authenticated
  user (in-app phishing). Move bell-row creation server-side; make insert
  service-role-only. (Pending.)
- ⬜ **Verify Storage RLS** on the `products` bucket: a vendor can only write to
  their own `<vendorId>/` folder; public read is fine for product images.
- ⬜ Add rate limiting on sensitive functions (payment/refund/bank/OTP).
- ⬜ Dump the live schema + RLS into version control (core tables were created
  outside migrations — schema drift).

## 7. Android build / Play Store

- ⬜ Create the **Play Console** app + store listing (title, descriptions,
  category, contact, privacy-policy URL).
- ⬜ App **icons** + feature graphic + **screenshots** (phone/tablet).
- ⬜ Set up the **release signing key** (upload key / Play App Signing); store
  the keystore safely.
- ⬜ Set a proper **applicationId**, version name/code, and `minSdk`/`targetSdk`
  to current Play requirements.
- ⬜ Complete the **Data Safety** form (what data is collected: email, location,
  photos, payment) and content rating.
- ⬜ Test a **release build** (`flutter build appbundle`) on a real device —
  native plugins added this cycle (`flutter_image_compress`, `share_plus`)
  must work in release/proguard.
- ⬜ **Deep links / Android App Links** once the domain exists, so a shared link
  opens the app when installed (asset-links file on the domain).

## 8. Notifications

- ⬜ Verify FCM push works in a release build (Firebase config, channels).

## 9. Known bugs to fix before launch

- ⬜ `disputes.vendor_response` column missing — breaks the vendor dashboard
  dispute load (seen on device; pre-existing).
- ⬜ Audit remaining `print()` calls — consider a logging framework / strip in
  release (optional, low priority).

## 10. Final pass

- ⬜ **Apply outstanding SQL migrations** to Supabase: `chat_receipts.sql` (chat
  delivery/read ticks). Already applied: `policy_acceptance.sql`,
  `store_handle.sql`.
- ⬜ Full end-to-end test: register → accept policy → browse → buy → pay →
  vendor request pickup → deliver → confirm → payout, plus refund path.
- ⬜ Smoke-test the policy gate for existing users (everyone re-signs once).
- ⬜ Remove any temporary/debug edge functions and test data.

---

## 11. After launch — Website (Phase 2)

The marketplace will also run on the web, with full feature parity with the app.
**Decision (2026-06-29):** build the website as a **separate web app (Next.js on
Vercel) against the same Supabase backend** — NOT Flutter compiled to web.

Why a web-native build, not Flutter Web:
- **SEO** — Next.js server-renders real HTML, so product pages get indexed by
  Google. Flutter Web (canvas/SPA) is barely crawlable; bad for a marketplace.
- **Link previews** — each product page can carry server-rendered Open Graph
  tags, so WhatsApp/Facebook show the image. (This makes the stopgap
  `share-product` edge function redundant — point `SHARE_BASE_URL` at the site.)
- **Speed** — fast first paint on poor networks vs Flutter Web's ~2MB+ engine.
- **Plugins** — camera, image-compression, push behave differently/not at all on
  web anyway, so "one codebase everywhere" isn't truly free.

Why it's cheaper than it sounds: the money/critical logic already lives in
Supabase (payments, escrow, delivery, refunds, payouts are edge functions; data
+ RLS in the DB). The website reuses ALL of that unchanged — it only
re-implements UI/screen flows in React.

Guiding principle (applies to app work NOW too): keep authoritative logic
server-side (edge functions / DB), keep both clients thin, so the web doesn't
have to duplicate business rules. (e.g. policy acceptance: the record is in the
DB, only the screen is per-client.)

Timing: **launch the app first** (this checklist), then build the website as
phase 2 on the same backend. Do not build both frontends at once.

Parity note: aim for ~full parity, but a few things adapt to the medium —
product photos become a file upload (vs camera), push becomes web-push/email.
The buyer/vendor/escrow experience can otherwise be identical.

---

## 12. Post-launch / scale (do NOT build pre-launch — watch signals)

Chat already has: realtime, optimistic send, delivery/read ticks, typing, and
scalable per-conversation receipt markers. The two enhancements below are
**not** launch blockers — implement them based on real usage signals, not a
date. Below the threshold, the current `postgres_changes` approach is fine.

**A. True "delivered" tick (✓✓ grey before read) — UX polish.**
- How: give each logged-in user ONE global subscription for messages addressed
  to them (add `messages.recipient_id`, filter on it), and mark
  `touch_chat_member(chat,'delivered')` on receipt — even when the chat isn't
  open. Today ticks usually jump straight sent → read.
- Cost: ~half a day to build; runtime = one extra realtime connection per online
  user + one small upsert per delivered message. Low risk.
- **Do it when:** users ask "did they get it?" / you want WhatsApp parity. Can be
  an early post-launch polish pass.

**B. Broadcast-from-Database for message fan-out — the scalability lever.**
- How: a Postgres trigger on `messages` calls `realtime.broadcast_changes('chat:'
  ||chat_id, …)`; clients subscribe to that private topic instead of
  `postgres_changes` on the table. Authorization is checked once at subscribe,
  not per-message-per-subscriber (which is what makes `postgres_changes` strain
  under high concurrency).
- Cost: ~1 day (trigger + client switch + Realtime channel authorization RLS).
  Runtime: sharply lower Realtime CPU per message — the main win.
- **Do it when:** monitoring shows it's time — message send→appear latency
  rising, missed/late messages, Realtime reconnects in logs, or Supabase
  dashboard Realtime CPU / connection count climbing under peak. Rough guide:
  `postgres_changes` is comfortable into the low thousands of *concurrent
  online* users (not 30k registered). Plan it as you approach a few thousand
  concurrent, or when bumping the Supabase compute tier.

**Monitoring:** weekly glance at Supabase → Realtime (peak connections,
messages/month) and Database (CPU), plus user complaints about chat speed. Those
trends are the trigger for B.
