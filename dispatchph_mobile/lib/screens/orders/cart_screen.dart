import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_image.dart';
import '../../bloc_exports.dart';
import 'checkout_screen.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  @override
  void initState() {
    super.initState();
    _loadCart();
  }

  Future<void> _loadCart() async {
    final prefs = await SharedPreferences.getInstance();
    final buyerId = prefs.getString('auth_user_id') ?? '';
    if (buyerId.isNotEmpty) {
      context.read<CartCubit>().loadCart(buyerId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cart')),
      body: BlocBuilder<CartCubit, CartState>(
        builder: (context, state) {
          if (state.items.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.shopping_cart_outlined, size: 64, color: AppColors.mediumGray),
                  const SizedBox(height: 16),
                  const Text('Your cart is empty', style: TextStyle(color: AppColors.mediumGray)),
                ],
              ),
            );
          }
          final format = NumberFormat('#,##0');
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: state.items.length,
                  itemBuilder: (_, i) {
                    final item = state.items[i];
                    final product = state.productMap[item.productId];
                    final unitPrice = item.variantPrice ?? product?.price ?? 0;
                    final lineTotal = unitPrice * item.quantity;

                    final images = product != null
                        ? (jsonDecode(product.images ?? '[]') as List)
                        : <dynamic>[];
                    final hasImage = images.isNotEmpty;

                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: AppColors.lightGray,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: hasImage
                                    ? AppImage(
                                        source: images.first.toString(),
                                        fit: BoxFit.cover,
                                      )
                                    : const Icon(Icons.image, color: AppColors.mediumGray),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    product?.name ?? 'Product',
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (item.variantLabel != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      item.variantLabel!,
                                      style: TextStyle(
                                        color: AppColors.primaryGreen,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 4),
                                  Text(
                                    '\u20A6${format.format(unitPrice)} each',
                                    style: TextStyle(fontSize: 12, color: AppColors.mediumGray),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '\u20A6${format.format(lineTotal)}',
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.primaryGreen,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    context.read<CartCubit>().updateQuantity(
                                        item.id, item.quantity - 1, item.buyerId);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: AppColors.lightGray,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.remove, size: 18, color: AppColors.charcoal),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${item.quantity}',
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                                ),
                                const SizedBox(height: 6),
                                GestureDetector(
                                  onTap: () {
                                    context.read<CartCubit>().updateQuantity(
                                        item.id, item.quantity + 1, item.buyerId);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                      color: AppColors.primaryGreen,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.add, size: 18, color: Colors.white),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))],
                ),
                child: SafeArea(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Total', style: TextStyle(color: AppColors.mediumGray)),
                            Text(
                              '\u20A6${format.format(state.total)}',
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          if (state.items.isEmpty) return;
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const CheckoutScreen()),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryGreen,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Checkout'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
