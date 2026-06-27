# DispatchPH — AI Session Summary

> **AI AGENTS**: Read `C:\Dispatch\AI_RULES.md` before making any changes. The rules in that file override everything else. Never change scope, architecture, or existing behavior without explicit user approval.

## Goal
- Transform DispatchPH from a dispatch-only app into a trust-first Nigerian e-commerce marketplace with escrow, photo-evidence delivery, dispute resolution, in-app chat, store reviews, push notifications, product variants, multi-image upload, and infinite-scroll pagination — backed by Supabase, targeting 30,000 users on slow Nigerian networks.

## Constraints & Preferences
- Test mode first (simulated payment, 30s escrow timer in debug) moving toward production
- Auto-release: 30s debug, 24h production — these values are by design, do NOT change
- Supabase over Firebase (SQL relational DB, predictable pricing, RLS, open-source)
- State management: BLoC/Cubit via flutter_bloc
- Role-based routing: buyer gets marketplace, vendor gets dashboard
- A buyer can buy from multiple vendors and chat with each one
- Evidence-based system: photos required for delivery confirmation and refund requests
- Vendor CANNOT mark "delivered" — only buyer can confirm with photo
- Auto-release timer (24h) starts when vendor marks "shipped", protects vendor from ghosting
- 48h dispute resolution window with automatic escalation to admin
- Phone + delivery address required from buyer when requesting refund
- Existing chat between buyer and vendor should be reused (no duplicate chats)
- Reviews system for vendor stores with 1-5 star ratings and comments
- Push notifications for all events (orders, chat, disputes) via FCM + Supabase Edge Functions
- Buyer orders split into Active/Delivered tabs (auto-move on confirmation)
- App must be fast on slow Nigerian networks — optimize queries, add caching, reduce payload sizes
- Product variants: vendor adds labeled options with own price/stock; buyer selects from chip selector and price auto-updates
- Multi-image upload: 3–4 images per product, file size displayed, auto-compress to 1200px/200KB, 2MB Supabase limit
- Vendor product listing: horizontal scrollable row, not vertical list
- Back button should NOT log out; only explicit logout button works

## Done
- **Query optimization (all `select()` calls eliminated)**: OrderBloc, DisputeBloc, ChatBloc, CartBloc, MarketplaceBloc, AuthService, all screens — now use specific column lists instead of `select()`
- **Chat performance**: `loadChatsForBuyer/Vendor` uses `Future.wait<dynamic>` for parallel unread + lastMessage queries; `sendMessage` removed extra chat/user lookups by passing `recipientId` from caller
- **Cart N+1 fix**: Single batch `inFilter('id', productIds)` instead of one query per product
- **Marketplace store N+1 fix**: Shared `_loadStoresFromProducts()` batch method returns map instead of mutating state
- **`CacheService`**: TTL-based in-memory cache service created at `core/services/cache_service.dart`
- **Pagination**: MarketplaceCubit loads 20 products per page via `.range(0, _pageSize - 1)`; infinite scroll in home screen via `NotificationListener<ScrollNotification>` triggering `loadMoreProducts()`, `loadMoreSearchResults()`, `loadMoreByCategory()`
- **Performance indexes SQL**: `C:\Dispatch\performance_indexes.sql` — 20+ indexes for products, orders, disputes, chats, messages, reviews, cart, users, stores with pg_trgm extension for search
- **`PopScope` back button fix**: MarketplaceHome + VendorDashboard wrapped with `PopScope(canPop: false)`, back on non-home tab goes to home, back on home shows "Press back again to exit" snackbar
- **Storage bucket auto-creation**: `initializeBuckets()` now also creates `products` bucket
- **AppUser.fromJson null-safety**: `email`, `name`, `role`, `created_at` fallback to defaults when null
- **Wrong column name fixes**: `products.image_url` → `products.images`; `stores.owner_id` → `stores.vendor_id`; `stores.logo_url` → `stores.logo_path`; `orders.product_id/product_name/…` → actual Order columns (store_id, items, total, status, etc.); removed `shipping_photo_at` from selects (column doesn't exist yet)
- **Unmodifiable map fix**: `_loadStoresFromProducts()` returns new map from `Map<String, Store>.from(existing)` instead of mutating `state.stores`
- **Evidence-based trust system built**: Mandatory photo for delivery confirmation, mandatory photo evidence for refund requests, vendor counter-evidence upload, 48h resolution timer with auto-escalation
- **Delivery flow overhauled**: Vendor can NO LONGER mark "delivered" — only buyer confirms with photo; auto-release (24h) starts when vendor marks "shipped"
- **Order model updated**: Added `riderName`, `riderPhone`, `deliveryMethod`, `shippingProofUrl`, `deliveryPhotoUrl`, `paymentReleased`, `shippedAt`, `confirmedAt`, `autoReleaseAt`
- **Dispute model updated**: Added `buyerId`, `vendorId`, `buyerPhone`, `deliveryAddress`, `issueType`, `evidenceUrls`, `vendorEvidenceUrls`, `resolutionDeadline`, `escalatedToAdmin`, `buyerExplanation`, `buyerSubmittedAt`, `vendorRespondedAt`
- **StorageService expanded**: `uploadDisputeEvidence`, `uploadShippingProof`, `uploadDeliveryConfirmation`, `initializeBuckets` (creates products, disputes, delivery buckets)
- **DeliveryConfirmationScreen**: Buyer takes mandatory photo to confirm delivery
- **RefundRequestScreen**: Buyer selects issue type, writes reason/explanation, provides phone + address, uploads 1-5 evidence photos
- **VendorShippingScreen**: Vendor enters rider name/phone, delivery method, optional shipping photo
- **Vendor dispute screens updated**: Shows buyer's phone, delivery address, evidence photos; vendor can upload counter-evidence
- **Cancel order feature**: Buyer can cancel when status is `paid` — full refund before vendor ships
- **Cancel dispute & confirm delivery**: Buyer can cancel an active dispute and confirm delivery with photo (payment releases)
- **Chat fallback fix**: `openChat()` finds ANY existing chat between buyer+vendor before creating new one — no duplicate chats
- **Review system**: New `reviews` table, `Review` model, `ReviewCubit` with load/submit/hasReviewed, `LeaveReviewScreen` with 1-5 star rating and comment
- **Review button on order detail**: Shows when status is `confirmed`, navigates to `LeaveReviewScreen`
- **ReviewCubit registered**: Added to `bloc_exports.dart` and `main.dart` `MultiBlocProvider`
- **Colors added**: `primaryBlue`, `warningOrange`, `starYellow` in `AppColors`
- **Dispute `fromJson` null-safety**: `vendorId`/`buyerId` made nullable
- **Status labels updated**: Buyer and vendor screens updated for new flow
- **Evidence system SQL schema**: `C:\Dispatch\evidence_system_schema.sql`
- **Phase 3 — Push Notifications (COMPLETE)**: Firebase project `dispatchph`, FCM token management via `FCMService`, Edge Function `send-push` with Firebase HTTP v1 API + JWT signing, push triggers in order_bloc/chat_bloc/dispute_bloc, `device_tokens` SQL table with RLS
- **Buyer Orders Split into Tabs**: Active (paid, shipped, delivered, refund_requested) / Delivered (confirmed, auto_released, refunded, cancelled) — auto-move with Realtime subscription + polling
- **Realtime + Polling for Order Updates**: OrderCubit Realtime channel, 10s buyer orders polling, 5s order/detail/vendor/dispute polling
- **Database schema migrations applied**: All missing order + dispute columns added (via `C:\Dispatch\fix_missing_columns.sql`)
- **Physical device testing**: Redmi 12 (Android arm64) — `adb push + pm install`, `flutter run` for dev
- **APK builds**: `flutter build apk --debug --target-platform android-arm64`
- **Supabase CLI**: v2.107.0, project linked to `takuhbkpagvhmxsncdls`
- **Product variants model and SQL**: `ProductVariant` model in `models.dart`, `product_variants_migration.sql` with RLS, `getVariants`/`addVariant`/`deleteVariant` in `MarketplaceCubit`, variant section in `AddProductScreen` (label/price/stock rows with add/remove)
- **Multi-image upload**: `AddProductScreen` shows file sizes, auto-compresses to 1200px/200KB, sequential upload with `LinearProgressIndicator` percentage, max 4 images
- **Image carousel**: `ProductDetailScreen` uses `PageView` + dot indicators + page counter for multi-image browsing
- **Variant picker**: `ProductDetailScreen` shows `Wrap` of `ChoiceChip` when variants exist; price auto-updates on selection
- **Horizontal product row**: Vendor dashboard products section converted from vertical `ListView.builder` inside `Expanded` to horizontal `ListView.separated` inside `SizedBox(height: 190)` with card-style product tiles (image, name, price, stock badge, popup menu); replaced `PopupMenuButton` with `_PopupMenu` widget, removed `_confirmDelete`, wrapped body in `SingleChildScrollView`

### In Progress
- Cart variant support: storing selected variant label/price when adding to cart

### Blocked
- `file_picker` dependency causes `CheckAarMetadataWorkAction` build failure — using `image_picker` only

## Key Decisions
- **Vendor CANNOT mark "delivered"**: Removed button entirely; only buyer can confirm delivery with photo — prevents vendor fraud
- **Auto-release starts at "shipped"**: 24h timer starts when vendor ships, not when vendor marks delivered — protects vendor from ghosting while preventing fake delivery claims
- **Chat fallback by buyer+vendor**: Reuses existing chat between the same buyer and vendor regardless of orderId — prevents duplicate conversations
- **Reviews per store**: Ratings and comments tied to store (not product), visible on vendor store screen — builds store reputation
- **Evidence-based system**: Photos required at every step (shipping, delivery, refund) creates audit trail
- **`chats.order_id` as text**: Accepts `"product_{productId}"` format; FK to orders dropped
- **FCM via Supabase Edge Functions**: Chosen over extending existing API (not in repo) — keeps everything in Supabase ecosystem
- **Firebase HTTP v1 API instead of firebase-admin SDK**: `npm:firebase-admin` fails in Deno Edge Runtime; implemented JWT signing + HTTP v1 API directly
- **Polling + Realtime dual approach**: Realtime subscription may not fire without explicit publication setup; polling as reliable fallback
- **Flat variant table (`product_variants`)**: One row per variant (label, price, stock), not combinatorial — simpler for vendors, no price-modifier calculation, stock per variant
- **Multi-image limit 4**: 1200px max dimension, 2MB per file (server-enforced), auto-compress JPEG quality 70
- **Back button intercepted with PopScope**: Prevents accidental logout; first press shows snackbar, second press exits
- **Image upload progress bar**: Sequential upload with `LinearProgressIndicator` per-image percentage
- **Variant price = final price**: Base price used only when no variants exist; each variant has its own absolute price (not price_modifier) — simplest for vendors

## Next Steps
- Add cart variant storage: store selected variant label + price in cart_items or items JSON
- Test full flow end-to-end on physical device: order with variant → ship → deliver → confirm → review, with push notifications
- Run `fix_missing_columns.sql` and `product_variants_migration.sql` in Supabase SQL Editor if not already done
- Create storage buckets in Supabase Dashboard if auto-creation fails (anon key lacks bucket creation permission)
- Revoke Supabase access token (used for Edge Function deployment only)
- Phase 4: Real payments (Paystack/Flutterwave)
- Phase 5: Delivery partner integration (riders) with GPS
- Production: Disable test mode, remove debug logging, secure remaining endpoints

## Critical Context
- **Supabase project**: URL `https://takuhbkpagvhmxsncdls.supabase.co` (anon key in `.env`)
- **Firebase project**: `dispatchph`, project number `545738368528`, app ID `1:545738368528:android:e42bb426f3c160bcd74c95`
- **Firebase service account**: `dispatchph-firebase-adminsdk-fbsvc@dispatchph.iam.gserviceaccount.com` — stored as `FIREBASE_SERVICE_ACCOUNT` secret in Supabase Edge Functions
- **Edge Function `send-push`**: Deployed at `https://takuhbkpagvhmxsncdls.supabase.co/functions/v1/send-push`
- **Physical device**: Redmi 12, `fbde084f7d7c`, ARM64
- **Buyer FCM token**: `erdAAgQzTCyowL8AAEBs9I:APA91bHQ2f3bZbfqP2rIX2zzui28S62_pU-VI6h3wgV2HRKnN9XL0utEsfjt-L_mqFqntGqxTs5JYvLN8cbRvr5pLrimnzjsinAjIThcjg-NrvKoxgN-gJE`
- **Buyer user ID**: `5bda7653-77b6-4f4a-b3e5-ab96f8f0178d` (buyer), `91338c7d-f61f-40e9-9974-b04655c1cee2` (vendor)
- **ProductVariants table**: `product_variants(id, product_id, label, price, stock, sort_order)` with RLS (anyone can read, authenticated can manage)
- **Storage bucket defaults**: `products` bucket must exist for image uploads; 2MB file_size_limit, JPEG/PNG/WEBP mime types; creating via SQL requires service_role, not anon key
- **Wrong column bugs fixed**: `products.image_url` (nonexistent), `stores.owner_id` (nonexistent), `stores.logo_url` (nonexistent), `orders.product_id/product_name/...` (nonexistent) — all corrected to match actual DB schema
- **Unmodifiable map fix**: `MarketplaceCubit._loadStoresFromProducts()` now returns new map instead of mutating `state.stores` (which was `const {}`)
- **Auto-release**: 30s in debug mode, 24h in production — set via `EscrowService.calculateAutoReleaseAt()`
- **Dispute timer**: 48h from creation, auto-escalates when expired
- **`flutter_local_notifications`** requires `isCoreLibraryDesugaringEnabled = true` and `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")`
- **APK build for physical device**: `flutter build apk --debug --target-platform android-arm64` then `adb push + pm install`
- **Dashboard horizontal product row**: Uses `SizedBox(height: 190)` with horizontal `ListView.separated`; each tile is 140px wide with image (110px), name, price, stock badge, and `_PopupMenu` (edit/delete); body wrapped in `SingleChildScrollView` to prevent overflow

## Relevant Files
- `C:\Dispatch\product_variants_migration.sql`: product_variants table + RLS + storage bucket limits SQL
- `C:\Dispatch\performance_indexes.sql`: 20+ indexes for scale to 30K users
- `C:\Dispatch\fix_missing_columns.sql`: Adds missing orders columns + creates storage buckets + RLS policies
- `C:\Dispatch\dispatchph_mobile\lib\core\blocs\marketplace_bloc.dart`: Pagination (20/page, range-based), variant methods (loadVariants/addVariant/deleteVariant), stores now returned from _loadStoresFromProducts not mutated
- `C:\Dispatch\dispatchph_mobile\lib\core\blocs\order_bloc.dart`: Optimized selects with actual Order columns, push triggers
- `C:\Dispatch\dispatchph_mobile\lib\core\blocs\chat_bloc.dart`: Parallel Future.wait for unread+lastMessage, sendMessage with recipientId param, specific field selects
- `C:\Dispatch\dispatchph_mobile\lib\core\blocs\cart_bloc.dart`: Batch product fetch with inFilter
- `C:\Dispatch\dispatchph_mobile\lib\core\blocs\dispute_bloc.dart`: Specific field selects via _disputeFields constant
- `C:\Dispatch\dispatchph_mobile\lib\core\blocs\review_bloc.dart`: No changes
- `C:\Dispatch\dispatchph_mobile\lib\core\models\models.dart`: ProductVariant model added, AppUser null-safe fromJson, all existing models
- `C:\Dispatch\dispatchph_mobile\lib\core\services\storage_service.dart`: compressImage/compressImages helpers, getFileSize, isUnderSizeLimit, uploadProductImages batch, initializeBuckets creates products bucket
- `C:\Dispatch\dispatchph_mobile\lib\core\services\cache_service.dart`: NEW — TTL-based in-memory cache
- `C:\Dispatch\dispatchph_mobile\lib\screens\vendor\add_product_screen.dart`: Multi-image upload (max 4, size display, auto-compress, progress bar), variant section (label/price/stock rows)
- `C:\Dispatch\dispatchph_mobile\lib\screens\marketplace\product_detail_screen.dart`: Image carousel (PageView + dot indicators + page counter), variant selector (Wrap of ChoiceChips), price auto-updates on selection
- `C:\Dispatch\dispatchph_mobile\lib\screens\marketplace\home_screen.dart`: PopScope back button intercept, infinite scroll via NotificationListener
- `C:\Dispatch\dispatchph_mobile\lib\screens\vendor\dashboard_screen.dart`: PopScope back button intercept, horizontal product row (SizedBox 190px, scrollDirection horizontal, card tiles with image/name/price/stock/_PopupMenu), body wrapped in SingleChildScrollView
- `C:\Dispatch\dispatchph_mobile\lib\screens\chat\chat_list_screen.dart`: Batch user+store fetch (inFilter instead of N+1)
- `C:\Dispatch\dispatchph_mobile\lib\core\services\auth_service.dart`: Optimized selects, null-safe getUserProfile
- `C:\Dispatch\dispatchph_mobile\lib\core\services\supabase_service.dart`: Init with storage bucket initialization
- `C:\Dispatch\dispatchph_mobile\lib\screens\orders\vendor_dispute_screen.dart`: Optimized order/store/user/product selects
- `C:\Dispatch\dispatchph_mobile\lib\screens\marketplace\vendor_store_screen.dart`: Optimized store selects
