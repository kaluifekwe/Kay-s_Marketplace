import 'dart:math';
import 'supabase_service.dart';

/// Helpers for the shareable store handle (the clean slug in a store's public
/// link, e.g. `chibueze-stores`). Auto-generated from the store name at
/// registration; can be made editable later.
class StoreService {
  /// Turn a store name into a URL-safe slug.
  static String slugify(String name) {
    var s = name.toLowerCase().trim();
    s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.length > 40) {
      s = s.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
    }
    return s.isEmpty ? 'store' : s;
  }

  /// A handle that's unique in the stores table: tries the plain slug, then
  /// appends a short random suffix on collision. (A `uniq_store_handle` index
  /// is the real guarantee; this just keeps handles clean and avoids most
  /// insert failures.)
  static Future<String> generateUniqueHandle(String name) async {
    final base = slugify(name);
    for (var attempt = 0; attempt < 6; attempt++) {
      final candidate = attempt == 0 ? base : '$base-${_suffix()}';
      try {
        final existing = await SupabaseService.client
            .from('stores')
            .select('id')
            .eq('handle', candidate)
            .maybeSingle();
        if (existing == null) return candidate;
      } catch (_) {
        return '$base-${_suffix()}';
      }
    }
    return '$base-${_suffix()}';
  }

  static String _suffix() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random();
    return List.generate(4, (_) => chars[r.nextInt(chars.length)]).join();
  }
}
