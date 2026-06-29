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

- ⬜ **Verify Storage RLS** on the `products` bucket: a vendor can only write to
  their own `<vendorId>/` folder; public read is fine for product images.
- ⬜ Review RLS on every table once more before launch (least privilege).
- ⬜ Confirm all secrets are server-side only (no keys in the app bundle beyond
  the public anon key).

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
