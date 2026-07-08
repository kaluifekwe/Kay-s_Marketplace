import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import 'product_detail_screen.dart';
import 'vendor_store_screen.dart';
import '../../widgets/delivery_badge.dart';
import '../../widgets/app_image.dart';
import '../../core/models/models.dart';

/// A product thumbnail for search rows — the real image if the product has one,
/// otherwise a neutral placeholder (never a broken image).
Widget _productThumb(Product p, double size) {
  const fallback = ColoredBox(
    color: AppColors.lightGray,
    child: Center(child: Icon(Icons.image, color: AppColors.mediumGray)),
  );
  final imgs = p.imageList;
  return ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: SizedBox(
      width: size,
      height: size,
      child: imgs.isEmpty
          ? fallback
          : AppImage(source: imgs.first, width: size, height: size, fit: BoxFit.cover, errorWidget: fallback),
    ),
  );
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _searchController = TextEditingController();
  bool _onlyMyState = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Search products or store ID...',
            hintStyle: TextStyle(color: Colors.white70),
            border: InputBorder.none,
            filled: false,
          ),
          onChanged: (q) => context.read<MarketplaceCubit>().searchProductsDebounced(q),
        ),
      ),
      body: BlocBuilder<MarketplaceCubit, MarketplaceState>(
        builder: (context, state) {
          if (state.isLoading) return const Center(child: CircularProgressIndicator());

          final query = state.searchQuery ?? '';
          final is4Digit = RegExp(r'^\d{4}$').hasMatch(query);
          final buyerState = state.buyerState;

          final visibleProducts = (_onlyMyState && buyerState != null)
              ? state.products.where((p) => p.vendorState == buyerState).toList()
              : state.products;

          final stateFilterBar = buyerState == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      const Icon(Icons.location_on, size: 14, color: AppColors.primaryGreen),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Show only $buyerState vendors',
                          style: const TextStyle(fontSize: 13, color: AppColors.charcoal),
                        ),
                      ),
                      Switch(
                        value: _onlyMyState,
                        activeColor: AppColors.primaryGreen,
                        onChanged: (v) => setState(() => _onlyMyState = v),
                      ),
                    ],
                  ),
                );

          if (state.searchedStore != null) {
            final store = state.searchedStore!;
            final format = NumberFormat('#,##0');
            final productCount = visibleProducts.where((p) => p.storeId == store.id).length;
            return Column(
              children: [
                stateFilterBar,
                Expanded(
                  child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => VendorStoreScreen(storeId: store.id)),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.primaryGreen.withAlpha(80)),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primaryGreen.withAlpha(15),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: AppColors.primaryGreen.withAlpha(20),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.store, color: AppColors.primaryGreen, size: 28),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                store.name,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                              if (store.address != null && store.address!.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  store.address!,
                                  style: const TextStyle(fontSize: 13, color: AppColors.mediumGray),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                '$productCount ${productCount == 1 ? 'product' : 'products'}',
                                style: const TextStyle(fontSize: 12, color: AppColors.mediumGray),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: AppColors.primaryGreen),
                      ],
                    ),
                  ),
                ),
                if (visibleProducts.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    'Products matching "$query"',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.mediumGray),
                  ),
                  const SizedBox(height: 8),
                  ...visibleProducts.map((p) {
                    final storeName = state.stores[p.storeId]?.name ?? 'Store';
                    final inState = buyerState == null || p.vendorState == null || p.vendorState == buyerState;
                    return Card(
                      child: ListTile(
                        leading: _productThumb(p, 48),
                        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$storeName \u2022 \u20A6${format.format(p.price)}'
                              '${p.vendorState != null ? ' \u2022 ${p.vendorState}' : ''}',
                            ),
                            const SizedBox(height: 2),
                            deliveryBadge(p.deliveryType),
                          ],
                        ),
                        trailing: inState
                            ? const Icon(Icons.chevron_right)
                            : const Icon(Icons.lock, size: 16, color: AppColors.mediumGray),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => ProductDetailScreen(product: p)),
                        ),
                      ),
                    );
                  }),
                ],
              ],
                  ),
                ),
              ],
            );
          }

          if (query.isNotEmpty && is4Digit && visibleProducts.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.storefront_outlined, size: 64, color: AppColors.mediumGray),
                  const SizedBox(height: 16),
                  const Text(
                    'No store found with that ID',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.charcoal),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Check the ID and try again',
                    style: TextStyle(fontSize: 13, color: AppColors.mediumGray),
                  ),
                ],
              ),
            );
          }

          if (visibleProducts.isEmpty) {
            return Column(
              children: [
                stateFilterBar,
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_off, size: 64, color: AppColors.mediumGray),
                        const SizedBox(height: 16),
                        Text(
                          _onlyMyState ? 'No results in $buyerState' : 'No results found',
                          style: const TextStyle(color: AppColors.mediumGray),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }

          final format = NumberFormat('#,##0');
          return Column(
            children: [
              stateFilterBar,
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: visibleProducts.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (_, i) {
                    final p = visibleProducts[i];
                    final storeName = state.stores[p.storeId]?.name ?? 'Store';
                    final inState = buyerState == null || p.vendorState == null || p.vendorState == buyerState;
                    return ListTile(
                      leading: _productThumb(p, 56),
                      title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '$storeName \u2022 \u20A6${format.format(p.price)}'
                        '${p.vendorState != null ? ' \u2022 ${p.vendorState}' : ''}',
                      ),
                      trailing: inState
                          ? const Icon(Icons.chevron_right)
                          : const Icon(Icons.lock, size: 16, color: AppColors.mediumGray),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ProductDetailScreen(product: p)),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
