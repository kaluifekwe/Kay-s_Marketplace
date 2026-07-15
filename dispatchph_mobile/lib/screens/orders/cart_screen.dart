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
  String _buyerId = '';

  // Multi-select delete state.
  bool _selectionMode = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _loadCart();
  }

  Future<void> _loadCart() async {
    final prefs = await SharedPreferences.getInstance();
    final buyerId = prefs.getString('auth_user_id') ?? '';
    _buyerId = buyerId;
    if (buyerId.isNotEmpty && mounted) {
      context.read<CartCubit>().loadCart(buyerId);
    }
  }

  void _enterSelection(String itemId) {
    setState(() {
      _selectionMode = true;
      _selected.add(itemId);
    });
  }

  void _toggle(String itemId) {
    setState(() {
      if (_selected.contains(itemId)) {
        _selected.remove(itemId);
      } else {
        _selected.add(itemId);
      }
      // Leaving selection empty exits selection mode.
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove items'),
        content: Text('Remove $count item${count == 1 ? '' : 's'} from your cart?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.errorRed),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await context.read<CartCubit>().removeItems(_selected.toList(), _buyerId);
    if (mounted) _exitSelection();
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear cart'),
        content: const Text('Remove all items from your cart? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.errorRed),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await context.read<CartCubit>().clearCart(_buyerId);
    if (mounted) _exitSelection();
  }

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0');
    return Scaffold(
      appBar: AppBar(
        leading: _selectionMode
            ? IconButton(icon: const Icon(Icons.close), onPressed: _exitSelection)
            : null,
        title: Text(_selectionMode ? '${_selected.length} selected' : 'Cart'),
        actions: [
          BlocBuilder<CartCubit, CartState>(
            builder: (context, state) {
              if (state.items.isEmpty) return const SizedBox.shrink();
              if (_selectionMode) {
                return IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete selected',
                  onPressed: _selected.isEmpty ? null : _deleteSelected,
                );
              }
              return PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'select') {
                    setState(() => _selectionMode = true);
                  } else if (v == 'clear') {
                    _clearAll();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'select', child: Text('Select items')),
                  PopupMenuItem(value: 'clear', child: Text('Clear all')),
                ],
              );
            },
          ),
        ],
      ),
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
                    final selected = _selected.contains(item.id);

                    return GestureDetector(
                      onLongPress: () => _enterSelection(item.id),
                      onTap: _selectionMode ? () => _toggle(item.id) : null,
                      child: Card(
                        color: selected ? AppColors.primaryGreen.withAlpha(20) : null,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              if (_selectionMode) ...[
                                Checkbox(
                                  value: selected,
                                  activeColor: AppColors.primaryGreen,
                                  onChanged: (_) => _toggle(item.id),
                                ),
                                const SizedBox(width: 4),
                              ],
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
                                          thumbWidth: 150,
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
                                      '₦${format.format(unitPrice)} each',
                                      style: TextStyle(fontSize: 12, color: AppColors.mediumGray),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '₦${format.format(lineTotal)}',
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryGreen,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // Quantity steppers only in normal mode; hidden while
                              // selecting so the row reads as a selectable item.
                              if (!_selectionMode)
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
                      ),
                    );
                  },
                ),
              ),
              _selectionMode
                  ? _buildSelectionBar(state, format)
                  : _buildCheckoutBar(state, format),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCheckoutBar(CartState state, NumberFormat format) {
    return Container(
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
                    '₦${format.format(state.total)}',
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
    );
  }

  Widget _buildSelectionBar(CartState state, NumberFormat format) {
    final allSelected = _selected.length == state.items.length;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))],
      ),
      child: SafeArea(
        child: Row(
          children: [
            TextButton.icon(
              onPressed: () {
                setState(() {
                  if (allSelected) {
                    _selected.clear();
                    _selectionMode = false;
                  } else {
                    _selected
                      ..clear()
                      ..addAll(state.items.map((e) => e.id));
                  }
                });
              },
              icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
              label: Text(allSelected ? 'Unselect all' : 'Select all'),
              style: TextButton.styleFrom(foregroundColor: AppColors.charcoal),
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: _selected.isEmpty ? null : _deleteSelected,
              icon: const Icon(Icons.delete_outline),
              label: Text('Delete (${_selected.length})'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.errorRed,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
