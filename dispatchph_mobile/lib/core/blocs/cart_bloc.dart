import 'package:flutter_bloc/flutter_bloc.dart';
import '../services/supabase_service.dart';
import '../models/models.dart';

class CartCubit extends Cubit<CartState> {
  CartCubit() : super(CartState());

  static const _cartFields = 'id, buyer_id, product_id, quantity, added_at, variant_label, variant_price';

  Future<void> loadCart(String buyerId) async {
    try {
      final data = await SupabaseService.client
          .from('cart_items')
          .select(_cartFields)
          .eq('buyer_id', buyerId)
          .order('added_at');

      final items = (data as List).map((c) => CartItem.fromJson(c)).toList();
      final productMap = <String, Product>{};
      double total = 0;

      if (items.isNotEmpty) {
        final productIds = items.map((i) => i.productId).toSet().toList();
        final productData = await SupabaseService.client
            .from('products')
            .select('id, store_id, name, description, price, images, category, stock, created_at, vendor_state, delivery_type')
            .inFilter('id', productIds);
        for (final p in (productData as List)) {
          final product = Product.fromJson(p);
          productMap[product.id] = product;
        }
        for (final item in items) {
          final product = productMap[item.productId];
          if (product != null) {
            final unitPrice = item.variantPrice ?? product.price;
            total += unitPrice * item.quantity;
          }
        }
      }

      emit(CartState(items: items, productMap: productMap, total: total));
    } catch (e) {
      print('[CartCubit] loadCart error: $e');
    }
  }

  Future<void> addItem(
    String buyerId,
    String productId, {
    String? variantLabel,
    double? variantPrice,
  }) async {
    try {
      final existing = await SupabaseService.client
          .from('cart_items')
          .select(_cartFields)
          .eq('buyer_id', buyerId)
          .eq('product_id', productId)
          .maybeSingle();

      if (existing != null) {
        await SupabaseService.client.from('cart_items').update({
          'quantity': (existing['quantity'] as int) + 1,
        }).eq('id', existing['id']);
      } else {
        await SupabaseService.client.from('cart_items').insert({
          'buyer_id': buyerId,
          'product_id': productId,
          'quantity': 1,
          'variant_label': variantLabel,
          'variant_price': variantPrice,
        });
      }
      await loadCart(buyerId);
    } catch (e) {
      print('[CartCubit] addItem error: $e');
    }
  }

  Future<void> updateQuantity(String cartItemId, int quantity, String buyerId) async {
    try {
      if (quantity <= 0) {
        await SupabaseService.client
            .from('cart_items')
            .delete()
            .eq('id', cartItemId);
      } else {
        await SupabaseService.client
            .from('cart_items')
            .update({'quantity': quantity}).eq('id', cartItemId);
      }
      await loadCart(buyerId);
    } catch (e) {
      print('[CartCubit] updateQuantity error: $e');
    }
  }

  /// Delete a specific set of cart items in one round-trip (multi-select
  /// delete on the cart screen).
  Future<void> removeItems(List<String> cartItemIds, String buyerId) async {
    if (cartItemIds.isEmpty) return;
    try {
      await SupabaseService.client
          .from('cart_items')
          .delete()
          .inFilter('id', cartItemIds);
      await loadCart(buyerId);
    } catch (e) {
      print('[CartCubit] removeItems error: $e');
    }
  }

  Future<void> clearCart(String buyerId) async {
    try {
      await SupabaseService.client
          .from('cart_items')
          .delete()
          .eq('buyer_id', buyerId);
      emit(CartState());
    } catch (e) {
      print('[CartCubit] clearCart error: $e');
    }
  }
}

class CartState {
  final List<CartItem> items;
  final Map<String, Product> productMap;
  final double total;

  CartState({
    this.items = const [],
    this.productMap = const {},
    this.total = 0,
  });

  int get itemCount => items.fold(0, (sum, item) => sum + item.quantity);
}
