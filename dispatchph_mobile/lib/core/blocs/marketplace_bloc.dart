import 'dart:async';
import 'dart:convert';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/supabase_service.dart';
import '../services/cache_service.dart';
import '../models/models.dart';

/// Cached first page of the buyer product feed (in-memory, short-lived), so
/// navigating back to the marketplace doesn't re-hit the database every time.
class _ProductPage {
  final List<Product> products;
  final Map<String, Store> stores;
  final bool hasMore;
  _ProductPage(this.products, this.stores, this.hasMore);
}

class MarketplaceCubit extends Cubit<MarketplaceState> {
  MarketplaceCubit() : super(MarketplaceState());

  static const _productFields = 'id, store_id, name, description, price, images, category, stock, created_at, vendor_state, delivery_type';
  static const _storeFields = 'id, name, vendor_id, description, logo_path, address, phone, created_at, whatsapp_number, show_phone_to_buyers, store_banner_url, response_time, is_verified';
  static const _pageSize = 20;

  Timer? _searchDebounce;

  /// The store whose products are currently shown on the vendor dashboard, so
  /// add/edit/delete can refresh that view without the caller passing it back.
  String? _activeStoreId;

  /// Debounced wrapper for [searchProducts] — call this from the search
  /// field's onChanged so a query isn't fired on every keystroke (each one
  /// is a real network round-trip, costly on slow/metered connections).
  void searchProductsDebounced(String query, {Duration delay = const Duration(milliseconds: 400)}) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(delay, () => searchProducts(query));
  }

  @override
  Future<void> close() {
    _searchDebounce?.cancel();
    return super.close();
  }

  /// Loads the current buyer's state so product cards/checkout can compare
  /// it against each product's vendor_state for the intrastate restriction.
  Future<void> loadBuyerState(String userId) async {
    try {
      final data = await SupabaseService.client
          .from('users')
          .select('state')
          .eq('id', userId)
          .maybeSingle();
      if (data != null) {
        emit(state.copyWith(buyerState: data['state'] as String?));
      }
    } catch (e) {
      print('[MarketplaceCubit] loadBuyerState error: $e');
    }
  }

  static const _sameStateKey = 'marketplace_same_state_only';

  /// Restore the persisted "my-state only" toggle into state (call once the
  /// buyer's state is known). Doesn't reload — the feed load reads the flag.
  Future<void> initSameStateFilter() async {
    final prefs = await SharedPreferences.getInstance();
    emit(state.copyWith(sameStateOnly: prefs.getBool(_sameStateKey) ?? false));
  }

  /// Flip the "show only my-state vendors" toggle, persist it, and reload the
  /// active view (browse / category / search) with the new filter.
  Future<void> setSameStateOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sameStateKey, value);
    emit(state.copyWith(sameStateOnly: value));
    if (state.searchQuery != null && state.searchQuery!.isNotEmpty) {
      await searchProducts(state.searchQuery!);
    } else if (state.selectedCategory != null) {
      await loadProductsByCategory(state.selectedCategory!);
    } else {
      await loadProducts(forceRefresh: true);
    }
  }

  /// Adds the vendor-state filter to a products query when the toggle is on.
  dynamic _stateFilter(dynamic q) {
    if (state.sameStateOnly && state.buyerState != null && state.buyerState!.isNotEmpty) {
      return q.eq('vendor_state', state.buyerState);
    }
    return q;
  }

  Future<Map<String, Store>> _loadStoresFromProducts(List<dynamic> productsData, Map<String, Store> existing) async {
    final storeIds = productsData.map((p) => p['store_id'] as String).where((id) => id.isNotEmpty).toSet();
    if (storeIds.isEmpty) return existing;
    final storeData = await SupabaseService.client
        .from('stores')
        .select(_storeFields)
        .inFilter('id', storeIds.toList());
    final updated = Map<String, Store>.from(existing);
    for (final s in (storeData as List)) {
      updated[s['id']] = Store.fromJson(s);
    }
    return updated;
  }

  static const _feedCacheKey = 'products:page0';
  static const _feedCacheTtl = Duration(minutes: 3);

  Future<void> loadProducts({bool forceRefresh = false}) async {
    // Serve the cached first page when fresh — avoids a DB round-trip every time
    // the buyer returns to the marketplace. Pull-to-refresh/retry pass force.
    if (!forceRefresh) {
      final cached = CacheService.get<_ProductPage>(_feedCacheKey);
      if (cached != null) {
        emit(state.copyWith(
          isLoading: false,
          products: cached.products,
          stores: cached.stores,
          hasMore: cached.hasMore,
          currentPage: 0,
          clearSelectedCategory: true,
        ));
        return;
      }
    }
    emit(state.copyWith(isLoading: true));
    try {
      final data = await _stateFilter(
        SupabaseService.client.from('products').select(_productFields),
      ).order('created_at', ascending: false).range(0, _pageSize - 1);

      final products = (data as List).map((p) => Product.fromJson(p)).toList();
      final stores = await _loadStoresFromProducts(data, {});
      final hasMore = products.length >= _pageSize;
      CacheService.set(_feedCacheKey, _ProductPage(products, stores, hasMore), ttl: _feedCacheTtl);
      emit(state.copyWith(
        isLoading: false,
        products: products,
        stores: stores,
        hasMore: hasMore,
        currentPage: 0,
        // "All" shows every product, so drop any active category filter — this
        // also makes the "All" chip highlight correctly again.
        clearSelectedCategory: true,
      ));
    } catch (e) {
      print('[MarketplaceCubit] loadProducts error: $e');
      emit(state.copyWith(isLoading: false));
    }
  }

  /// Drop the cached feed so the next load fetches fresh (after a product is
  /// added/edited/deleted).
  void _invalidateFeedCache() => CacheService.clearPrefix('products:');

  /// Loads ALL of one store's products for the vendor dashboard, newest first.
  /// Unlike [loadProducts] this is filtered by store and not paginated, so the
  /// vendor always sees their full catalogue regardless of how many products
  /// exist platform-wide.
  Future<void> loadStoreProducts(String storeId) async {
    _activeStoreId = storeId;
    emit(state.copyWith(isLoadingStoreProducts: true));
    try {
      final data = await SupabaseService.client
          .from('products')
          .select(_productFields)
          .eq('store_id', storeId)
          .order('created_at', ascending: false);

      final products = (data as List).map((p) => Product.fromJson(p)).toList();
      emit(state.copyWith(storeProducts: products, isLoadingStoreProducts: false));
    } catch (e) {
      print('[MarketplaceCubit] loadStoreProducts error: $e');
      emit(state.copyWith(isLoadingStoreProducts: false));
    }
  }

  /// Re-fetch the active store's products after a mutation, so the dashboard
  /// updates without a manual refresh.
  Future<void> _refreshActiveStore() async {
    _invalidateFeedCache();
    if (_activeStoreId != null) await loadStoreProducts(_activeStoreId!);
  }

  /// Replace a single product in BOTH the buyer feed (state.products) and the
  /// vendor catalogue (storeProducts) with its current DB row. The vendor's
  /// store screen renders from state.products, which _refreshActiveStore never
  /// touched — so without this, edits (images, price, etc.) didn't reflect
  /// there or in the product detail opened from it.
  Future<void> _refreshProductInState(String productId) async {
    try {
      final data = await SupabaseService.client
          .from('products')
          .select(_productFields)
          .eq('id', productId)
          .maybeSingle();
      if (data == null) return;
      final fresh = Product.fromJson(data);
      List<Product> replace(List<Product> list) =>
          list.map((p) => p.id == productId ? fresh : p).toList();
      emit(state.copyWith(
        products: replace(state.products),
        storeProducts: replace(state.storeProducts),
      ));
    } catch (e) {
      print('[MarketplaceCubit] _refreshProductInState error: $e');
    }
  }

  Future<void> loadMoreProducts() async {
    if (state.isLoadingMore || !state.hasMore) return;
    emit(state.copyWith(isLoadingMore: true));
    try {
      final nextPage = state.currentPage + 1;
      final from = nextPage * _pageSize;
      final to = from + _pageSize - 1;

      final data = await _stateFilter(
        SupabaseService.client.from('products').select(_productFields),
      ).order('created_at', ascending: false).range(from, to);

      final newProducts = (data as List).map((p) => Product.fromJson(p)).toList();
      final stores = await _loadStoresFromProducts(data, state.stores);

      final allProducts = [...state.products, ...newProducts];
      emit(state.copyWith(
        isLoadingMore: false,
        products: allProducts,
        stores: stores,
        hasMore: newProducts.length >= _pageSize,
        currentPage: nextPage,
      ));
    } catch (e) {
      print('[MarketplaceCubit] loadMoreProducts error: $e');
      emit(state.copyWith(isLoadingMore: false));
    }
  }

  /// Clear an active search and restore the browse feed (respecting any category
  /// filter). Called when returning to the home feed from the search screen so
  /// it isn't left showing stale search results. No-op if nothing was searched;
  /// the feed itself comes from cache, so this is effectively instant.
  Future<void> resetFeed() async {
    if (state.searchQuery == null || state.searchQuery!.isEmpty) return;
    emit(state.copyWith(clearSearchQuery: true));
    if (state.selectedCategory != null) {
      await loadProductsByCategory(state.selectedCategory!);
    } else {
      await loadProducts();
    }
  }

  Future<void> searchProducts(String query) async {
    emit(state.copyWith(isLoading: true, searchQuery: query, searchedStore: null));
    try {
      Store? foundStore;
      if (RegExp(r'^\d{4,6}$').hasMatch(query)) {
        try {
          final userData = await SupabaseService.client
              .from('users')
              .select('id, store_id')
              .eq('unique_id', query)
              .maybeSingle();
          if (userData != null && userData['store_id'] != null && (userData['store_id'] as String).isNotEmpty) {
            final storeData = await SupabaseService.client
                .from('stores')
                .select(_storeFields)
                .eq('id', userData['store_id'])
                .maybeSingle();
            if (storeData != null) {
              foundStore = Store.fromJson(storeData);
            }
          }
        } catch (_) {}
      }

      List<dynamic> data;
      if (query.isEmpty) {
        data = await _stateFilter(
          SupabaseService.client.from('products').select(_productFields),
        ).order('created_at', ascending: false).range(0, _pageSize - 1);
      } else {
        data = await _stateFilter(
          SupabaseService.client
              .from('products')
              .select(_productFields)
              .or('name.ilike.%$query%,description.ilike.%$query%'),
        ).order('created_at', ascending: false).range(0, _pageSize - 1);
      }

      final products = (data as List).map((p) => Product.fromJson(p)).toList();
      final stores = await _loadStoresFromProducts(data, {});
      if (foundStore != null) {
        stores[foundStore.id] = foundStore;
      }
      emit(state.copyWith(
        isLoading: false,
        products: products,
        stores: stores,
        searchedStore: foundStore,
        hasMore: products.length >= _pageSize,
        currentPage: 0,
      ));
    } catch (e) {
      print('[MarketplaceCubit] searchProducts error: $e');
      emit(state.copyWith(isLoading: false));
    }
  }

  Future<void> loadMoreSearchResults() async {
    if (state.isLoadingMore || !state.hasMore) return;
    emit(state.copyWith(isLoadingMore: true));
    try {
      final nextPage = state.currentPage + 1;
      final from = nextPage * _pageSize;
      final to = from + _pageSize - 1;
      final query = state.searchQuery ?? '';

      List<dynamic> data;
      if (query.isEmpty) {
        data = await _stateFilter(
          SupabaseService.client.from('products').select(_productFields),
        ).order('created_at', ascending: false).range(from, to);
      } else {
        data = await _stateFilter(
          SupabaseService.client
              .from('products')
              .select(_productFields)
              .or('name.ilike.%$query%,description.ilike.%$query%'),
        ).order('created_at', ascending: false).range(from, to);
      }

      final newProducts = (data as List).map((p) => Product.fromJson(p)).toList();
      final stores = await _loadStoresFromProducts(data, state.stores);

      final allProducts = [...state.products, ...newProducts];
      emit(state.copyWith(
        isLoadingMore: false,
        products: allProducts,
        stores: stores,
        hasMore: newProducts.length >= _pageSize,
        currentPage: nextPage,
      ));
    } catch (e) {
      print('[MarketplaceCubit] loadMoreSearchResults error: $e');
      emit(state.copyWith(isLoadingMore: false));
    }
  }

  Future<void> loadProductsByCategory(String category) async {
    emit(state.copyWith(isLoading: true));
    try {
      final data = await _stateFilter(
        SupabaseService.client.from('products').select(_productFields).eq('category', category),
      ).order('created_at', ascending: false).range(0, _pageSize - 1);

      final products = (data as List).map((p) => Product.fromJson(p)).toList();
      final stores = await _loadStoresFromProducts(data, {});
      emit(state.copyWith(
        isLoading: false,
        products: products,
        stores: stores,
        selectedCategory: category,
        hasMore: products.length >= _pageSize,
        currentPage: 0,
      ));
    } catch (e) {
      print('[MarketplaceCubit] loadProductsByCategory error: $e');
      emit(state.copyWith(isLoading: false));
    }
  }

  Future<void> loadMoreByCategory() async {
    if (state.isLoadingMore || !state.hasMore || state.selectedCategory == null) return;
    emit(state.copyWith(isLoadingMore: true));
    try {
      final nextPage = state.currentPage + 1;
      final from = nextPage * _pageSize;
      final to = from + _pageSize - 1;

      final data = await _stateFilter(
        SupabaseService.client.from('products').select(_productFields).eq('category', state.selectedCategory!),
      ).order('created_at', ascending: false).range(from, to);

      final newProducts = (data as List).map((p) => Product.fromJson(p)).toList();
      final stores = await _loadStoresFromProducts(data, state.stores);

      final allProducts = [...state.products, ...newProducts];
      emit(state.copyWith(
        isLoadingMore: false,
        products: allProducts,
        stores: stores,
        hasMore: newProducts.length >= _pageSize,
        currentPage: nextPage,
      ));
    } catch (e) {
      print('[MarketplaceCubit] loadMoreByCategory error: $e');
      emit(state.copyWith(isLoadingMore: false));
    }
  }

  void setSelectedCategory(String? category) {
    emit(state.copyWith(selectedCategory: category));
  }

  Future<String?> addProduct(
    String storeId,
    String name,
    String? description,
    double price,
    String category,
    int stock, {
    List<String> images = const [],
    List<ProductVariant> variants = const [],
    String deliveryType = 'negotiate',
  }) async {
    try {
      final result = await SupabaseService.client.from('products').insert({
        'store_id': storeId,
        'name': name,
        'description': description,
        'price': price,
        'images': jsonEncode(images),
        'category': category,
        'stock': stock,
        'delivery_type': deliveryType,
      }).select('id').maybeSingle();

      if (result == null) return 'Failed to create product';

      if (variants.isNotEmpty) {
        for (final v in variants) {
          try {
            await SupabaseService.client.from('product_variants').insert({
              'product_id': result['id'],
              'label': v.label,
              'price': v.price,
              'stock': v.stock,
              'image_url': v.imageUrl,
              'sort_order': v.sortOrder,
            });
          } catch (ve) {
            print('[MarketplaceCubit] addVariant insert error: $ve');
          }
        }
      }
      _invalidateFeedCache();
      await loadStoreProducts(storeId);
      return null;
    } catch (e) {
      print('[MarketplaceCubit] addProduct error: $e');
      return e.toString();
    }
  }

  Future<void> updateProduct(
    String productId,
    String name,
    String? description,
    double price,
    String category,
    int stock, {
    String? deliveryType,
  }) async {
    try {
      await SupabaseService.client.from('products').update({
        'name': name,
        'description': description,
        'price': price,
        'category': category,
        'stock': stock,
        if (deliveryType != null) 'delivery_type': deliveryType,
      }).eq('id', productId);
      await _refreshActiveStore();
      await _refreshProductInState(productId);
    } catch (e) {
      print('[MarketplaceCubit] updateProduct error: $e');
    }
  }

  Future<void> updateProductImages(String productId, List<String> images) async {
    try {
      await SupabaseService.client.from('products').update({
        'images': jsonEncode(images),
      }).eq('id', productId);
      await _refreshActiveStore();
      await _refreshProductInState(productId);
    } catch (e) {
      print('[MarketplaceCubit] updateProductImages error: $e');
    }
  }

  Future<void> deleteProduct(String productId) async {
    try {
      await SupabaseService.client.from('products').delete().eq('id', productId);
      await _refreshActiveStore();
    } catch (e) {
      print('[MarketplaceCubit] deleteProduct error: $e');
    }
  }

  // --- Variant methods ---

  Future<List<ProductVariant>> loadVariants(String productId, {bool forceRefresh = false}) async {
    try {
      // The in-memory cache is only a first-paint optimization. Without
      // forceRefresh it would return whatever was loaded first for the app's
      // lifetime, so a variant added later (here or on another device) never
      // showed until restart. Screens that must reflect edits pass forceRefresh.
      if (!forceRefresh) {
        final cached = state.variants[productId];
        if (cached != null && cached.isNotEmpty) return cached;
      }

      final data = await SupabaseService.client
          .from('product_variants')
          .select('id, product_id, label, price, stock, image_url, sort_order')
          .eq('product_id', productId)
          .order('sort_order', ascending: true);
      final variants = (data as List).map((v) => ProductVariant.fromJson(v)).toList();
      final updated = Map<String, List<ProductVariant>>.from(state.variants);
      updated[productId] = variants;
      emit(state.copyWith(variants: updated));
      return variants;
    } catch (e) {
      print('[MarketplaceCubit] loadVariants error: $e');
      return [];
    }
  }

  Future<String?> addVariant(String productId, String label, double price, int stock, {String? imageUrl}) async {
    try {
      final data = await SupabaseService.client
          .from('product_variants')
          .insert({
            'product_id': productId,
            'label': label,
            'price': price,
            'stock': stock,
            'image_url': imageUrl,
            'sort_order': await _nextVariantSortOrder(productId),
          })
          .select('id, product_id, label, price, stock, image_url, sort_order')
          .maybeSingle();
      if (data != null) {
        final variant = ProductVariant.fromJson(data);
        final existing = List<ProductVariant>.from(state.variants[productId] ?? []);
        existing.add(variant);
        final updated = Map<String, List<ProductVariant>>.from(state.variants);
        updated[productId] = existing;
        emit(state.copyWith(variants: updated));
      }
      return null;
    } catch (e) {
      print('[MarketplaceCubit] addVariant error: $e');
      return e.toString();
    }
  }

  Future<int> _nextVariantSortOrder(String productId) async {
    final data = await SupabaseService.client
        .from('product_variants')
        .select('sort_order')
        .eq('product_id', productId)
        .order('sort_order', ascending: false)
        .limit(1)
        .maybeSingle();
    if (data == null) return 0;
    return (data['sort_order'] as int) + 1;
  }

  Future<void> deleteVariant(String variantId, String productId) async {
    try {
      await SupabaseService.client.from('product_variants').delete().eq('id', variantId);
      final existing = state.variants[productId]?.where((v) => v.id != variantId).toList() ?? [];
      final updated = Map<String, List<ProductVariant>>.from(state.variants);
      updated[productId] = existing;
      emit(state.copyWith(variants: updated));
    } catch (e) {
      print('[MarketplaceCubit] deleteVariant error: $e');
    }
  }
}

class MarketplaceState {
  final bool isLoading;
  final bool isLoadingMore;
  final List<Product> products;
  final Map<String, Store> stores;
  final String? searchQuery;
  final String? selectedCategory;
  final bool hasMore;
  final int currentPage;
  final Map<String, List<ProductVariant>> variants;
  final Store? searchedStore;
  final String? buyerState;

  /// The vendor dashboard's own product list (one store, full catalogue).
  /// Kept separate from [products] (the paginated buyer feed) so buyer-side
  /// browsing never clobbers what the vendor sees on their dashboard.
  final List<Product> storeProducts;
  final bool isLoadingStoreProducts;

  /// When true, the buyer feed is restricted to vendors in the buyer's own
  /// state (the "Show only my-state vendors" toggle). Off = all states.
  final bool sameStateOnly;

  MarketplaceState({
    this.isLoading = false,
    this.isLoadingMore = false,
    List<Product>? products,
    this.stores = const {},
    this.searchQuery,
    this.selectedCategory,
    this.hasMore = true,
    this.currentPage = 0,
    this.variants = const {},
    this.searchedStore,
    this.buyerState,
    List<Product>? storeProducts,
    this.isLoadingStoreProducts = false,
    this.sameStateOnly = false,
  })  : products = products ?? [],
        storeProducts = storeProducts ?? [];

  MarketplaceState copyWith({
    bool? isLoading,
    bool? isLoadingMore,
    List<Product>? products,
    Map<String, Store>? stores,
    String? searchQuery,
    String? selectedCategory,
    bool? hasMore,
    int? currentPage,
    Map<String, List<ProductVariant>>? variants,
    Store? searchedStore,
    String? buyerState,
    List<Product>? storeProducts,
    bool? isLoadingStoreProducts,
    bool? sameStateOnly,
    // Because copyWith uses `?? this`, passing selectedCategory: null can't
    // clear it. Set this to reset back to "All" (no category filter).
    bool clearSelectedCategory = false,
    // Same reason — set this to clear an active search query (back to browse).
    bool clearSearchQuery = false,
  }) {
    return MarketplaceState(
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      products: products ?? this.products,
      stores: stores ?? this.stores,
      searchQuery: clearSearchQuery ? null : (searchQuery ?? this.searchQuery),
      selectedCategory: clearSelectedCategory ? null : (selectedCategory ?? this.selectedCategory),
      hasMore: hasMore ?? this.hasMore,
      currentPage: currentPage ?? this.currentPage,
      variants: variants ?? this.variants,
      searchedStore: searchedStore ?? this.searchedStore,
      buyerState: buyerState ?? this.buyerState,
      storeProducts: storeProducts ?? this.storeProducts,
      isLoadingStoreProducts: isLoadingStoreProducts ?? this.isLoadingStoreProducts,
      sameStateOnly: sameStateOnly ?? this.sameStateOnly,
    );
  }
}
