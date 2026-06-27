import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../chat/chat_screen.dart';
import '../delivery/courier_track_tile.dart';
import 'vendor_shipping_screen.dart';

String _vendorOrderStatusLabel(String status) {
  switch (status) {
    case 'paid': return 'Payment Held in Escrow';
    case 'shipped': return 'Shipped — Awaiting buyer confirmation (24h)';
    case 'confirmed': return 'Completed — Payment Released';
    case 'cancelled': return 'Cancelled — Buyer cancelled';
    case 'refund_requested': return 'Refund Requested';
    case 'refunded': return 'Refunded';
    case 'auto_released': return 'Auto-Released to Vendor';
    default: return status;
  }
}

class VendorOrderDetailScreen extends StatefulWidget {
  final Order order;
  const VendorOrderDetailScreen({super.key, required this.order});

  @override
  State<VendorOrderDetailScreen> createState() => _VendorOrderDetailScreenState();
}

class _VendorOrderDetailScreenState extends State<VendorOrderDetailScreen> {
  String _buyerName = 'Buyer';
  String _buyerUniqueId = '';
  String _buyerPhone = '';
  String _buyerAddress = '';

  @override
  void initState() {
    super.initState();
    _loadBuyerInfo();
  }

  Future<void> _loadBuyerInfo() async {
    Map<String, dynamic>? userData;
    try {
      userData = await SupabaseService.client
          .from('users')
          .select('id, name, phone, unique_id, address')
          .eq('id', widget.order.buyerId)
          .maybeSingle();
    } catch (_) {
      userData = await SupabaseService.client
          .from('users')
          .select('id, name, phone')
          .eq('id', widget.order.buyerId)
          .maybeSingle();
    }
    if (userData != null && mounted) {
      setState(() {
        _buyerName = userData!['name'] as String? ?? 'Buyer';
        _buyerUniqueId = userData['unique_id'] as String? ?? '';
        _buyerPhone = userData['phone'] as String? ?? '';
        _buyerAddress = userData['address'] as String? ?? '';
      });
    }
  }

  Widget _buyerInfoRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.primaryGreen),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: AppColors.mediumGray)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildItemList(String itemsJson) {
    try {
      final items = jsonDecode(itemsJson) as List;
      if (items.isEmpty) return [const Text('No items', style: TextStyle(color: AppColors.mediumGray))];
      final format = NumberFormat('#,##0');
      return items.map((item) {
        final name = item['name'] ?? 'Item';
        final quantity = item['quantity'] ?? 1;
        final price = (item['price'] as num?)?.toDouble() ?? 0;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text('$name x$quantity', style: const TextStyle(fontSize: 14)),
              ),
              Text('\u20A6${format.format(price * quantity)}',
                  style: const TextStyle(fontWeight: FontWeight.w500)),
            ],
          ),
        );
      }).toList();
    } catch (_) {
      return [const Text('Items', style: TextStyle(color: AppColors.mediumGray))];
    }
  }

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0');
    final order = widget.order;

    return Scaffold(
      appBar: AppBar(title: Text('Order #${order.id.substring(0, 8)}')),
      body: BlocBuilder<OrderCubit, OrderState>(
        builder: (context, state) {
          final currentOrder = state.vendorOrders.where((o) => o.id == order.id).firstOrNull ?? order;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _StatusBanner(order: currentOrder),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Order Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 8),
                      ..._buildItemList(currentOrder.items),
                      const Divider(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Total', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                          Text('\u20A6${format.format(currentOrder.total)}',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: AppColors.primaryGreen)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Buyer Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 12),
                      _buyerInfoRow(Icons.tag, 'ID', _buyerUniqueId.isNotEmpty ? _buyerUniqueId : 'N/A'),
                      const SizedBox(height: 8),
                      _buyerInfoRow(Icons.person, 'Name', _buyerName),
                      const SizedBox(height: 8),
                      _buyerInfoRow(Icons.phone, 'Phone', _buyerPhone.isNotEmpty ? _buyerPhone : 'N/A'),
                      const SizedBox(height: 8),
                      _buyerInfoRow(Icons.location_on, 'Address', _buyerAddress.isNotEmpty ? _buyerAddress : 'N/A'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (currentOrder.hasShipbubbleDelivery && currentOrder.deliveryId != null) ...[
                CourierTrackTile(deliveryId: currentOrder.deliveryId!),
                const SizedBox(height: 16),
              ],
              // A courier was booked automatically for this order — the vendor
              // doesn't mark it shipped; the courier's pickup drives status.
              if (currentOrder.status == 'paid' && !currentOrder.hasShipbubbleDelivery)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      // Parse items from order
                      List<Map<String, dynamic>> items = [];
                      try {
                        final decoded = jsonDecode(currentOrder.items);
                        if (decoded is List) {
                          items = decoded.cast<Map<String, dynamic>>();
                        }
                      } catch (_) {}
                      
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => BlocProvider.value(
                            value: context.read<OrderCubit>(),
                            child: VendorShippingScreen(order: currentOrder, items: items),
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.local_shipping),
                    label: const Text('Mark as Shipped'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.refundOrange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              if (currentOrder.status == 'confirmed')
                _InfoRow(icon: Icons.check_circle, text: 'Payment released to you', color: AppColors.successGreen),
              if (currentOrder.status == 'auto_released')
                _InfoRow(icon: Icons.timer_off, text: 'Auto-released to you', color: AppColors.mediumGray),
              if (currentOrder.status == 'refund_requested')
                _InfoRow(icon: Icons.report_problem, text: 'Buyer requested refund — review needed', color: AppColors.errorRed),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(
                        orderId: currentOrder.id,
                        buyerId: currentOrder.buyerId,
                        vendorId: currentOrder.vendorId,
                        vendorName: 'You',
                        buyerName: _buyerName,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.chat),
                  label: const Text('Chat with Buyer'),
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.primaryGreen),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final Order order;
  const _StatusBanner({required this.order});

  @override
  Widget build(BuildContext context) {
    Color bg;
    IconData icon;
    switch (order.status) {
      case 'paid':
        bg = AppColors.escrowBlue;
        icon = Icons.lock;
        break;
      case 'shipped':
        bg = AppColors.refundOrange;
        icon = Icons.local_shipping;
        break;
      case 'delivered':
        bg = AppColors.successGreen;
        icon = Icons.check_circle;
        break;
      case 'confirmed':
        bg = AppColors.successGreen;
        icon = Icons.verified;
        break;
      case 'refund_requested':
      case 'refunded':
        bg = AppColors.errorRed;
        icon = Icons.money_off;
        break;
      default:
        bg = AppColors.mediumGray;
        icon = Icons.info;
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: bg.withAlpha(80)),
      ),
      child: Row(
        children: [
          Icon(icon, color: bg, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Status', style: TextStyle(fontSize: 12, color: AppColors.mediumGray)),
                Text(_vendorOrderStatusLabel(order.status), style: TextStyle(fontWeight: FontWeight.w600, color: bg)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const _InfoRow({required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color ?? AppColors.mediumGray),
          const SizedBox(width: 8),
          Text(text, style: TextStyle(color: color ?? AppColors.charcoal)),
        ],
      ),
    );
  }
}
