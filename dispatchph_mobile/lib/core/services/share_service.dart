import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:share_plus/share_plus.dart';

/// Shares a product to WhatsApp / Facebook / Instagram / etc. via the native
/// share sheet. The shared link points at a public web page (the `share-product`
/// Supabase Edge Function for now) that renders the product with Open Graph
/// tags, so chat/feed previews show the image and tapping opens the page with a
/// "Get the app" button.
class ShareService {
  /// Base for product share links. Defaults to the Supabase Edge Function.
  /// Set `SHARE_BASE_URL` in `.env` to your own domain once it's live
  /// (e.g. https://kaysmarketplace.com) — then links become `/p/<id>`.
  static String _shareBase() {
    final override = dotenv.env['SHARE_BASE_URL'];
    if (override != null && override.isNotEmpty) {
      return override.replaceAll(RegExp(r'/+$'), '');
    }
    final supabaseUrl =
        (dotenv.env['SUPABASE_URL'] ?? '').replaceAll(RegExp(r'/+$'), '');
    return '$supabaseUrl/functions/v1/share-product';
  }

  static String productUrl(String productId) {
    final base = _shareBase();
    // Edge-function form uses ?id=; a custom domain page uses /p/<id>.
    return base.contains('share-product')
        ? '$base?id=$productId'
        : '$base/p/$productId';
  }

  /// Public storefront URL for a vendor. Prefers the clean handle; falls back
  /// to the store id. On a custom domain it's `/store/<handle>`; on the edge
  /// function it's the `share-store` sibling with `?handle=`/`?id=`.
  static String storeUrl({String? handle, String? storeId}) {
    final override = dotenv.env['SHARE_BASE_URL'];
    final hasDomain = override != null && override.isNotEmpty;
    final slug = (handle != null && handle.isNotEmpty) ? handle : null;
    if (hasDomain) {
      final base = override.replaceAll(RegExp(r'/+$'), '');
      return slug != null ? '$base/store/$slug' : '$base/store/$storeId';
    }
    final supabaseUrl =
        (dotenv.env['SUPABASE_URL'] ?? '').replaceAll(RegExp(r'/+$'), '');
    final fn = '$supabaseUrl/functions/v1/share-store';
    return slug != null ? '$fn?handle=$slug' : '$fn?id=$storeId';
  }

  static String _naira(double price) {
    final digits = price.toStringAsFixed(0);
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return '₦$buf';
  }

  /// Open the share sheet for a product. Shares the product image (so it shows
  /// on WhatsApp status / Instagram, where links aren't tappable) together with
  /// a caption + link. Falls back to text-only if the image can't be fetched.
  static Future<void> shareProduct({
    required String productId,
    required String name,
    required double price,
    String? imageUrl,
  }) async {
    final url = productUrl(productId);
    final caption = "$name\n${_naira(price)}\n\nSee it on Kays Market:\n$url";
    try {
      if (imageUrl != null && imageUrl.startsWith('http')) {
        final file = await DefaultCacheManager().getSingleFile(imageUrl);
        await SharePlus.instance.share(
          ShareParams(text: caption, files: [XFile(file.path)]),
        );
        return;
      }
    } catch (e) {
      debugPrint('[ShareService] image share failed, falling back to text: $e');
    }
    await SharePlus.instance.share(ShareParams(text: caption, subject: name));
  }

  /// Open the share sheet for a whole store (the vendor's "store link"). Shares
  /// the store banner/logo if available, plus a caption + storefront link.
  static Future<void> shareStore({
    String? handle,
    String? storeId,
    required String storeName,
    String? imageUrl,
  }) async {
    final url = storeUrl(handle: handle, storeId: storeId);
    final caption =
        "🛍️ $storeName on Kays Market\n\nBrowse all my products here:\n$url";
    try {
      if (imageUrl != null && imageUrl.startsWith('http')) {
        final file = await DefaultCacheManager().getSingleFile(imageUrl);
        await SharePlus.instance.share(
          ShareParams(text: caption, files: [XFile(file.path)]),
        );
        return;
      }
    } catch (e) {
      debugPrint('[ShareService] store image share failed, text only: $e');
    }
    await SharePlus.instance.share(ShareParams(text: caption, subject: storeName));
  }
}
