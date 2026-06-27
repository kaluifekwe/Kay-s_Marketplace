import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/services/auth_service.dart';
import '../../core/models/models.dart';
import 'vendor_order_detail_screen.dart';
import 'vendor_shipping_screen.dart';

class VendorOrdersScreen extends StatefulWidget {
  const VendorOrdersScreen({super.key});

  @override
  State<VendorOrdersScreen> createState() => _VendorOrdersScreenState();
}

class _VendorOrdersScreenState extends State<VendorOrdersScreen> {
  Timer? _refreshTimer;
  String _selectedFilter = 'All';

  @override
  void initState() {
    super.initState();
    _loadOrders();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadOrders());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadOrders() async {
    final vendorId = await AuthService.getUserId();
    if (vendorId.isNotEmpty && mounted) {
      context.read<OrderCubit>().loadVendorOrders(vendorId);
    }
  }

  List<Order> _filterOrders(List<Order> orders) {
    if (_selectedFilter == 'All') return orders;
    final now = DateTime.now();
    return orders.where((o) {
      final d = o.createdAt;
      switch (_selectedFilter) {
        case 'Today':
          return d.year == now.year && d.month == now.month && d.day == now.day;
        case 'This Week':
          final weekAgo = now.subtract(const Duration(days: 7));
          return d.isAfter(weekAgo);
        case 'This Month':
          return d.year == now.year && d.month == now.month;
        default:
          return true;
      }
    }).toList();
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return DateFormat('h:mm a').format(dt);
    if (diff.inDays < 7) return DateFormat('EEE, h:mm a').format(dt);
    return DateFormat('MMM d, h:mm a').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Orders')),
      body: BlocBuilder<OrderCubit, OrderState>(
        builder: (context, state) {
          if (state.isLoading) return const Center(child: CircularProgressIndicator());

          final filtered = _filterOrders(state.vendorOrders);

          if (state.vendorOrders.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.receipt_long, size: 64, color: AppColors.mediumGray),
                  const SizedBox(height: 16),
                  const Text('No orders yet', style: TextStyle(color: AppColors.mediumGray)),
                ],
              ),
            );
          }

          final format = NumberFormat('#,##0');
          return Column(
            children: [
              _buildFilterBar(state.vendorOrders.length),
              if (filtered.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(
                      'No orders for "$_selectedFilter"',
                      style: const TextStyle(color: AppColors.mediumGray, fontSize: 14),
                    ),
                  ),
                )
              else
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _loadOrders,
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final order = filtered[i];
                        Color statusColor;
                        String statusLabel;
                        switch (order.status) {
                          case 'paid':
                            statusColor = AppColors.escrowBlue;
                            statusLabel = 'Payment Received';
                            break;
                          case 'shipped':
                            statusColor = AppColors.primaryGreen;
                            statusLabel = 'Shipped';
                            break;
                          case 'confirmed':
                            statusColor = AppColors.successGreen;
                            statusLabel = 'Delivered';
                            break;
                          case 'auto_released':
                            statusColor = AppColors.successGreen;
                            statusLabel = 'Auto-Released';
                            break;
                          default:
                            statusColor = AppColors.mediumGray;
                            statusLabel = order.status;
                        }
                        final dateStr = _formatDate(order.createdAt);
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: ExpansionTile(
                            leading: Container(
                              width: 8,
                              decoration: BoxDecoration(
                                color: statusColor,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            title: Text('Order #${order.id.substring(0, 8)}',
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(Icons.circle, color: statusColor, size: 8),
                                    const SizedBox(width: 6),
                                    Text(statusLabel, style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w500)),
                                    const Spacer(),
                                    Text('\u20A6${format.format(order.total)}',
                                        style: const TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(Icons.access_time, color: AppColors.mediumGray, size: 12),
                                    const SizedBox(width: 4),
                                    Text(dateStr, style: const TextStyle(color: AppColors.mediumGray, fontSize: 11)),
                                  ],
                                ),
                              ],
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onExpansionChanged: (_) {},
                            children: [
                              if (order.status == 'paid')
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () {
                                        List<Map<String, dynamic>> items = [];
                                        try {
                                          final decoded = jsonDecode(order.items);
                                          if (decoded is List) {
                                            items = decoded.cast<Map<String, dynamic>>();
                                          }
                                        } catch (_) {}

                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => BlocProvider.value(
                                              value: context.read<OrderCubit>(),
                                              child: VendorShippingScreen(order: order, items: items),
                                            ),
                                          ),
                                        );
                                      },
                                      icon: const Icon(Icons.local_shipping, size: 18),
                                      label: const Text('Mark as Shipped'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.refundOrange,
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => VendorOrderDetailScreen(order: order),
                                      ),
                                    ),
                                    icon: const Icon(Icons.visibility, size: 18),
                                    label: const Text('View Details'),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilterBar(int totalCount) {
    final filters = ['All', 'Today', 'This Week', 'This Month'];
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text('$totalCount orders',
              style: const TextStyle(fontSize: 12, color: AppColors.mediumGray)),
          const SizedBox(width: 12),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final f = filters[i];
                final selected = f == _selectedFilter;
                return ChoiceChip(
                  label: Text(f, style: TextStyle(
                    fontSize: 12,
                    color: selected ? Colors.white : AppColors.charcoal,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  )),
                  selected: selected,
                  selectedColor: AppColors.primaryGreen,
                  backgroundColor: Colors.grey[100],
                  onSelected: (_) => setState(() => _selectedFilter = f),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
