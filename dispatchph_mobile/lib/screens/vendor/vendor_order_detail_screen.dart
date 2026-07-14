import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/services/error_text.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/delivery_service.dart';
import '../../widgets/app_image.dart';
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
  String? _buyerAvatar;
  bool _requestingPickup = false;

  @override
  void initState() {
    super.initState();
    _loadBuyerInfo();
  }

  /// Confirm the item is actually packaged before dispatching a courier — a
  /// premature booking means a wasted pickup (and, once enabled, a charge to
  /// the vendor for the failed-pickup courier fee).
  Future<void> _confirmAndRequestPickup(Order order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Is the order packaged and ready?'),
        content: const Text(
          'The courier will be dispatched to your pickup address to collect it now. '
          'Only request pickup once the item is packaged — a failed pickup wastes the '
          'courier trip and may be charged to you.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not yet')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryGreen, foregroundColor: Colors.white),
            child: const Text('Yes, it\'s ready'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _requestPickup(order);
  }

  /// Vendor taps "Request Pickup" after packaging — the server re-quotes and
  /// books a fresh courier, then we reload so the track tile appears.
  Future<void> _requestPickup(Order order) async {
    if (_requestingPickup) return;
    setState(() => _requestingPickup = true);
    try {
      final result = await DeliveryService.requestPickup(order.id);
      if (!mounted) return;
      if (result['booked'] == true) {
        await context.read<OrderCubit>().loadVendorOrders(order.vendorId);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Courier booked! It will come to your pickup address to collect the item.'),
            backgroundColor: AppColors.successGreen,
          ),
        );
      } else {
        final msg = (result['message'] as String?) ??
            'No courier available right now. Please try again shortly.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: AppColors.warningOrange),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.errorRed),
        );
      }
    } finally {
      if (mounted) setState(() => _requestingPickup = false);
    }
  }

  Future<void> _loadBuyerInfo() async {
    try {
      // Scoped RPC: a vendor may see the full contact (incl. photo) of a buyer
      // who ordered from them. (Buyers' rows aren't readable cross-user.)
      final rows = await SupabaseService.client
          .rpc('order_buyer_contact', params: {'p_order_id': widget.order.id});
      final data = (rows is List && rows.isNotEmpty) ? rows.first as Map<String, dynamic> : null;
      if (data != null && mounted) {
        setState(() {
          _buyerName = data['name'] as String? ?? 'Buyer';
          _buyerUniqueId = data['unique_id'] as String? ?? '';
          _buyerPhone = data['phone'] as String? ?? '';
          _buyerAddress = data['address'] as String? ?? '';
          _buyerAvatar = data['avatar_url'] as String?;
        });
      }
    } catch (e) {
      print('[VendorOrderDetail] loadBuyerInfo error: $e');
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
                          const Text('Subtotal', style: TextStyle(color: AppColors.mediumGray)),
                          Text('\u20A6${format.format(currentOrder.total)}', style: const TextStyle(color: AppColors.mediumGray)),
                        ],
                      ),
                      if (currentOrder.deliveryFee > 0) ...[
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(currentOrder.deliveryType == 'courier' ? 'Delivery (courier)' : 'Delivery',
                                style: const TextStyle(color: AppColors.mediumGray)),
                            Text('\u20A6${format.format(currentOrder.deliveryFee)}', style: const TextStyle(color: AppColors.mediumGray)),
                          ],
                        ),
                      ],
                      const Divider(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Total', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                          Text('\u20A6${format.format(currentOrder.totalWithDelivery ?? currentOrder.total)}',
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
                      if (_buyerAvatar != null && _buyerAvatar!.isNotEmpty)
                        Center(
                          child: GestureDetector(
                            onTap: () => showDialog(
                              context: context,
                              builder: (_) => Dialog(
                                backgroundColor: Colors.black,
                                insetPadding: const EdgeInsets.all(12),
                                child: Stack(
                                  alignment: Alignment.topRight,
                                  children: [
                                    InteractiveViewer(child: AppImage(source: _buyerAvatar, fit: BoxFit.contain)),
                                    IconButton(
                                      icon: const Icon(Icons.close, color: Colors.white),
                                      onPressed: () => Navigator.pop(context),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            child: CircleAvatar(
                              radius: 32,
                              backgroundColor: AppColors.primaryGreen.withAlpha(20),
                              child: ClipOval(child: AppImage(source: _buyerAvatar, width: 64, height: 64, fit: BoxFit.cover)),
                            ),
                          ),
                        ),
                      if (_buyerAvatar != null && _buyerAvatar!.isNotEmpty) const SizedBox(height: 12),
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
              // Courier order, not yet booked: the vendor requests pickup once
              // the item is packed (server re-quotes + books a fresh courier).
              if (currentOrder.status == 'paid' &&
                  currentOrder.deliveryType == 'courier' &&
                  !currentOrder.hasShipbubbleDelivery) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5EB),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.primaryGreen),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Package the item, then request a courier pickup. The courier will '
                        'come to your pickup address to collect it.',
                        style: TextStyle(fontSize: 13),
                      ),
                      if (currentOrder.pickupDeadline != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          '⏰ Request pickup before ${DateFormat('MMM d, h:mm a').format(currentOrder.pickupDeadline!.toLocal())} — '
                          'otherwise the order is auto-cancelled and the buyer refunded.',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.warningOrange),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _requestingPickup ? null : () => _confirmAndRequestPickup(currentOrder),
                    icon: _requestingPickup
                        ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.delivery_dining, color: Colors.white),
                    label: Text(_requestingPickup ? 'Booking courier…' : 'Request Pickup',
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              // Self / negotiated delivery: vendor marks shipped manually.
              if (currentOrder.status == 'paid' &&
                  !currentOrder.hasShipbubbleDelivery &&
                  currentOrder.deliveryType != 'courier')
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
