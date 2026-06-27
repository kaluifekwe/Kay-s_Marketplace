import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import 'product_detail_screen.dart';

class CategoryBrowseScreen extends StatelessWidget {
  final String category;
  const CategoryBrowseScreen({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(category)),
      body: BlocBuilder<MarketplaceCubit, MarketplaceState>(
        builder: (context, state) {
          final products = state.products.where((p) => p.category == category).toList();
          if (products.isEmpty) {
            return const Center(child: Text('No products in this category'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: products.length,
            itemBuilder: (_, i) => Card(
              child: ListTile(
                leading: Container(
                  width: 48, height: 48,
                  color: AppColors.lightGray,
                  child: const Icon(Icons.image, color: AppColors.mediumGray),
                ),
                title: Text(products[i].name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ProductDetailScreen(product: products[i])),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
