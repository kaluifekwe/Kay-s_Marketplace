import '../models/models.dart';
import 'supabase_service.dart';

/// Buyer's saved "My Stores" — add a vendor's store by the short numeric ID
/// the vendor shares (users.unique_id), then open it any time.
class SavedStoresService {
  static const _storeCols =
      'id, name, vendor_id, description, logo_path, address, phone, created_at, store_banner_url, is_verified';

  /// Resolve a shared numeric ID to a store. Returns null if no store matches.
  static Future<Store?> resolveByUniqueId(String uniqueId) async {
    final id = uniqueId.trim();
    if (id.isEmpty) return null;
    try {
      // unique_id lives on the vendor's user row, exposed via public_profiles.
      final prof = await SupabaseService.client
          .from('public_profiles')
          .select('id')
          .eq('unique_id', id)
          .maybeSingle();
      final vendorId = prof?['id'] as String?;
      if (vendorId == null) return null;
      final store = await SupabaseService.client
          .from('stores')
          .select(_storeCols)
          .eq('vendor_id', vendorId)
          .maybeSingle();
      return store != null ? Store.fromJson(store) : null;
    } catch (e) {
      print('[SavedStores] resolveByUniqueId error: $e');
      return null;
    }
  }

  static Future<List<Store>> list() async {
    final uid = SupabaseService.auth.currentUser?.id;
    if (uid == null) return [];
    try {
      final rows = await SupabaseService.client
          .from('saved_stores')
          .select('store_id')
          .eq('buyer_id', uid)
          .order('created_at', ascending: false);
      final ids = (rows as List).map((r) => r['store_id'] as String).toList();
      if (ids.isEmpty) return [];
      final data = await SupabaseService.client.from('stores').select(_storeCols).inFilter('id', ids);
      final stores = (data as List).map((s) => Store.fromJson(s)).toList();
      // Preserve saved order (newest first).
      stores.sort((a, b) => ids.indexOf(a.id).compareTo(ids.indexOf(b.id)));
      return stores;
    } catch (e) {
      print('[SavedStores] list error: $e');
      return [];
    }
  }

  static Future<bool> isSaved(String storeId) async {
    final uid = SupabaseService.auth.currentUser?.id;
    if (uid == null) return false;
    try {
      final row = await SupabaseService.client
          .from('saved_stores')
          .select('store_id')
          .eq('buyer_id', uid)
          .eq('store_id', storeId)
          .maybeSingle();
      return row != null;
    } catch (_) {
      return false;
    }
  }

  static Future<void> add(String storeId) async {
    final uid = SupabaseService.auth.currentUser?.id;
    if (uid == null) return;
    await SupabaseService.client.from('saved_stores').upsert(
      {'buyer_id': uid, 'store_id': storeId},
      onConflict: 'buyer_id,store_id',
      ignoreDuplicates: true,
    );
  }

  static Future<void> remove(String storeId) async {
    final uid = SupabaseService.auth.currentUser?.id;
    if (uid == null) return;
    await SupabaseService.client
        .from('saved_stores')
        .delete()
        .eq('buyer_id', uid)
        .eq('store_id', storeId);
  }
}
