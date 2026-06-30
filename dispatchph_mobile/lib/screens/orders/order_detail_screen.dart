import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/auth_service.dart';
import '../chat/chat_screen.dart';
import '../delivery/courier_track_tile.dart';
import '../marketplace/vendor_store_screen.dart';
import 'buyer_dispute_screen.dart';
import 'delivery_confirmation_screen.dart';
import 'refund_request_screen.dart';
import 'leave_review_screen.dart';

String orderStatusLabel(String status) {
  switch (status) {
    case 'paid': return 'Payment Held in Escrow';
    case 'shipped': return 'Shipped — Confirm or report a problem';
    case 'confirmed': return 'Completed — Payment Released';
    case 'cancelled': return 'Cancelled — Refunded';
    case 'refund_requested': return 'Refund Requested';
    case 'refunded': return 'Refunded';
    case 'auto_released': return 'Auto-Released to Vendor';
    default: return status;
  }
}

class OrderDetailScreen extends StatefulWidget {
  final String orderId;
  const OrderDetailScreen({super.key, required this.orderId});

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  Order? _order;
  StreamSubscription<Duration>? _timerSub;
  Duration _remaining = Duration.zero;
  String _vendorName = 'Vendor';
  String? _disputeId;
  Timer? _refreshTimer;
  bool _hasReviewed = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _loadOrder();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadOrder());
  }

  Future<void> _loadOrder() async {
    final cubit = context.read<OrderCubit>();
    Order? order = cubit.state.buyerOrders.where((o) => o.id == widget.orderId).firstOrNull
        ?? cubit.state.vendorOrders.where((o) => o.id == widget.orderId).firstOrNull;

    // Fallback: fetch the order directly when it isn't in the in-memory lists
    // (e.g. opened from a notification before the orders list has loaded).
    // Without this the screen spun forever.
    if (order == null) {
      try {
        final data = await SupabaseService.client
            .from('orders')
            .select('id, buyer_id, vendor_id, store_id, items, total, status, payment_reference, shipping_method, tracking_ref, rider_name, rider_phone, delivery_method, shipping_proof_url, delivery_photo_url, payment_released, paid_at, shipped_at, delivered_at, confirmed_at, auto_release_at, refunded_at, created_at, delivery_type, delivery_fee, vendor_delivery_contribution, total_with_delivery, has_shipbubble_delivery, delivery_id, pickup_deadline')
            .eq('id', widget.orderId)
            .maybeSingle();
        if (data != null) order = Order.fromJson(data);
      } catch (e) {
        print('[OrderDetail] load error: $e');
      }
    }

    if (order == null) {
      if (mounted) setState(() => _loadFailed = true);
      return;
    }

    {
      setState(() => _order = order);
      final storeData = await SupabaseService.client.from('stores').select('id, name, vendor_id, description, logo_path, address, phone').eq('vendor_id', order.vendorId).maybeSingle();
      final store = storeData != null ? Store.fromJson(storeData) : null;
      if (mounted) setState(() => _vendorName = store?.name ?? 'Vendor');
      if (order.status == 'shipped') {
        _timerSub = cubit.watchTimer(widget.orderId).listen((d) {
          if (mounted) setState(() => _remaining = d);
        });
      }

      final disputeData = await SupabaseService.client
          .from('disputes')
          .select('id')
          .eq('order_id', widget.orderId)
          .maybeSingle();
      if (disputeData != null && mounted) {
        setState(() => _disputeId = disputeData['id'] as String);
      }

      if (order.status == 'confirmed') {
        final userId = await AuthService.getUserId();
        final reviewed = await context.read<ReviewCubit>().hasReviewed(order.storeId, userId, orderId: order.id);
        if (mounted) setState(() => _hasReviewed = reviewed);
      }
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _timerSub?.cancel();
    super.dispose();
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
        final variantLabel = item['variant_label'] as String?;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$name x$quantity',
                      style: const TextStyle(fontSize: 14),
                    ),
                    if (variantLabel != null)
                      Text(
                        variantLabel,
                        style: TextStyle(fontSize: 12, color: AppColors.primaryGreen),
                      ),
                  ],
                ),
              ),
              Text(
                '\u20A6${format.format(price * quantity)}',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
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
    return Scaffold(
      appBar: AppBar(title: Text('Order #${widget.orderId.substring(0, 8)}')),
      body: _order == null
          ? (_loadFailed
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, size: 48, color: AppColors.mediumGray),
                        const SizedBox(height: 12),
                        const Text("Couldn't load this order. It may have been removed.",
                            textAlign: TextAlign.center, style: TextStyle(color: AppColors.mediumGray)),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () {
                            setState(() => _loadFailed = false);
                            _loadOrder();
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : const Center(child: CircularProgressIndicator()))
          : BlocBuilder<OrderCubit, OrderState>(
              builder: (context, state) {
                final order = state.buyerOrders.where((o) => o.id == widget.orderId).firstOrNull ?? _order!;
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _StatusBanner(order: order),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => VendorStoreScreen(storeId: order.storeId)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.store, size: 16, color: AppColors.primaryGreen),
                          const SizedBox(width: 6),
                          Text(_vendorName,
                              style: const TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 4),
                          const Icon(Icons.chevron_right, size: 16, color: AppColors.primaryGreen),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Order Items', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            const SizedBox(height: 8),
                            ..._buildItemList(order.items),
                            const Divider(),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Total', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                                Text('\u20A6${format.format(order.total)}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: AppColors.primaryGreen)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (order.hasShipbubbleDelivery && order.deliveryId != null) ...[
                      CourierTrackTile(deliveryId: order.deliveryId!),
                      const SizedBox(height: 16),
                    ],
                    if (order.status == 'shipped') ...[
                      _TimerCard(remaining: _remaining),
                      const SizedBox(height: 16),
                      // Delivery info
                      if (order.riderName != null || order.riderPhone != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.escrowBlue.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.motorcycle, color: AppColors.escrowBlue, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Rider: ${order.riderName ?? "N/A"} — ${order.riderPhone ?? "N/A"}',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _confirmDelivery(context, order),
                              icon: const Icon(Icons.check_circle),
                              label: const Text('Confirm & Release'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.successGreen,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _requestRefund(context, order),
                              icon: const Icon(Icons.report_problem),
                              label: const Text('Request Refund'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.errorRed,
                                side: const BorderSide(color: AppColors.errorRed),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'You have 24 hours from shipment to confirm or report a problem — '
                        'once you confirm (or the window passes), this order can no longer be disputed for most reasons. '
                        '"Item not received" can still be reported any time after that.',
                        style: TextStyle(fontSize: 11, color: AppColors.mediumGray),
                      ),
                    ],
                    if (order.status == 'paid') ...[
                      if (order.hasShipbubbleDelivery) ...[
                        // A rider has been booked (see the tracking tile above).
                        // The order can no longer be cancelled — the buyer waits
                        // for delivery, or reports a problem once it ships.
                        _InfoRow(icon: Icons.motorcycle, text: 'A rider has been booked for your order'),
                      ] else ...[
                        _InfoRow(icon: Icons.hourglass_empty, text: 'Awaiting the vendor to ship your order'),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _cancelOrder(context, order),
                            icon: const Icon(Icons.cancel_outlined),
                            label: const Text('Cancel Order'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.mediumGray,
                              side: const BorderSide(color: AppColors.mediumGray),
                            ),
                          ),
                        ),
                      ],
                    ],
                    if (order.status == 'confirmed' && !_hasReviewed) ...[
                      _InfoRow(icon: Icons.check_circle, text: 'Payment released to vendor', color: AppColors.successGreen),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => _leaveReview(context, order),
                          icon: const Icon(Icons.star),
                          label: const Text('Leave a Review'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.starYellow,
                            foregroundColor: AppColors.charcoal,
                          ),
                        ),
                      ),
                    ],
                    if (order.status == 'confirmed' && _hasReviewed) ...[
                      _InfoRow(icon: Icons.check_circle, text: 'Payment released to vendor', color: AppColors.successGreen),
                      const SizedBox(height: 8),
                      _InfoRow(icon: Icons.star, text: 'You already reviewed this store', color: AppColors.starYellow),
                    ],
                    if (order.status == 'refund_requested')
                      _InfoRow(icon: Icons.report_problem, text: 'Refund requested — vendor will review'),
                    if (_disputeId != null && order.status != 'refunded' && order.status != 'cancelled') ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => BlocProvider.value(
                                    value: context.read<DisputeCubit>(),
                                    child: BuyerDisputeScreen(disputeId: _disputeId!),
                                  ),
                                ),
                              ).then((_) => _loadOrder()),
                              icon: const Icon(Icons.gavel),
                              label: const Text('View Dispute'),
                              style: OutlinedButton.styleFrom(foregroundColor: AppColors.escrowBlue),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => _cancelDisputeAndConfirm(context, order, _disputeId!),
                          icon: const Icon(Icons.check_circle),
                          label: const Text('Cancel Dispute & Confirm Delivery'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.successGreen,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ],
                    if (order.status == 'refunded')
                      _InfoRow(icon: Icons.money_off, text: 'Payment refunded', color: AppColors.refundOrange),
                    if (order.status == 'auto_released')
                      _InfoRow(icon: Icons.timer_off, text: 'Auto-released to vendor', color: AppColors.mediumGray),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatScreen(
                              orderId: widget.orderId,
                              buyerId: order.buyerId,
                              vendorId: order.vendorId,
                              vendorName: _vendorName,
                              buyerName: 'You',
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.chat),
                        label: const Text('Chat with Vendor'),
                        style: OutlinedButton.styleFrom(foregroundColor: AppColors.primaryGreen),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }

  void _confirmDelivery(BuildContext context, Order order) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DeliveryConfirmationScreen(order: order),
      ),
    );
  }

  void _cancelOrder(BuildContext context, Order order) {
    // Cancellation is only offered before a rider is booked, so this is always a
    // full refund. Once a rider is booked the button is hidden (and the server
    // rejects it) — the buyer waits for delivery or reports a problem.
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel Order'),
        content: const Text('Are you sure? This will cancel the order and issue a full refund.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Keep Order')),
          ElevatedButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final cubit = context.read<OrderCubit>();
              Navigator.pop(context);
              final error = await cubit.cancelOrder(order.id, order.buyerId);
              messenger.showSnackBar(SnackBar(
                content: Text(error ?? 'Order cancelled and refunded to Kay\'s Credit.'),
              ));
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.mediumGray, foregroundColor: Colors.white),
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _cancelDisputeAndConfirm(BuildContext context, Order order, String disputeId) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo of Received Item'),
              subtitle: const Text('Confirm you received the order'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Processing...'),
          ],
        ),
      ),
    );

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 80);

    if (picked == null) {
      if (mounted) Navigator.pop(context);
      return;
    }

    final success = await context.read<DisputeCubit>().cancelDisputeAndConfirm(
      disputeId: disputeId,
      orderId: order.id,
      buyerId: order.buyerId,
      deliveryPhotoPath: picked.path,
    );

    if (mounted) Navigator.pop(context);

    if (success) {
      await context.read<OrderCubit>().loadBuyerOrders(order.buyerId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Dispute cancelled. Delivery confirmed! Payment released.'),
            backgroundColor: AppColors.successGreen,
          ),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to confirm. Please try again.'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  void _requestRefund(BuildContext context, Order order) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RefundRequestScreen(order: order),
      ),
    );
  }

  void _leaveReview(BuildContext context, Order order) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LeaveReviewScreen(
          storeId: order.storeId,
          orderId: order.id,
          storeName: _vendorName,
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final Order order;
  const _StatusBanner({required this.order});

  Color _getStatusColor(String status) {
    switch (status) {
      case 'paid':
        return AppColors.warningOrange;
      case 'shipped':
        return AppColors.primaryBlue;
      case 'confirmed':
        return AppColors.successGreen;
      case 'cancelled':
        return AppColors.mediumGray;
      case 'refund_requested':
      case 'refunded':
        return AppColors.errorRed;
      case 'auto_released':
        return AppColors.escrowBlue;
      default:
        return AppColors.mediumGray;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'paid':
        return Icons.hourglass_top;
      case 'shipped':
        return Icons.local_shipping;
      case 'confirmed':
        return Icons.check_circle;
      case 'cancelled':
        return Icons.cancel;
      case 'refund_requested':
      case 'refunded':
        return Icons.money_off;
      case 'auto_released':
        return Icons.timer;
      default:
        return Icons.info;
    }
  }

  String _getStatusLabel(String status) {
    switch (status) {
      case 'paid':
        return 'Pending';
      case 'shipped':
        return 'Shipped';
      case 'confirmed':
        return 'Delivered';
      case 'cancelled':
        return 'Cancelled';
      case 'refund_requested':
        return 'Disputed';
      case 'refunded':
        return 'Refunded';
      case 'auto_released':
        return 'Auto-Released';
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _getStatusColor(order.status);
    final icon = _getStatusIcon(order.status);
    final label = _getStatusLabel(order.status);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withAlpha(30),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      orderStatusLabel(order.status),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.mediumGray,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildOrderTimeline(order.status),
        ],
      ),
    );
  }

  Widget _buildOrderTimeline(String currentStatus) {
    final steps = ['paid', 'shipped', 'confirmed'];
    final currentIndex = steps.indexOf(currentStatus);

    return Row(
      children: List.generate(steps.length * 2 - 1, (index) {
        if (index.isOdd) {
          final stepIndex = index ~/ 2;
          final isCompleted = stepIndex < currentIndex;
          return Expanded(
            child: Container(
              height: 3,
              color: isCompleted ? AppColors.successGreen : AppColors.mediumGray.withAlpha(80),
            ),
          );
        } else {
          final stepIndex = index ~/ 2;
          final isCompleted = stepIndex <= currentIndex;
          final isCurrent = stepIndex == currentIndex;
          return Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: isCompleted ? AppColors.successGreen : AppColors.mediumGray.withAlpha(80),
              shape: BoxShape.circle,
              border: isCurrent
                  ? Border.all(color: AppColors.successGreen, width: 2)
                  : null,
            ),
            child: isCompleted
                ? const Icon(Icons.check, color: Colors.white, size: 14)
                : Center(
                    child: Text(
                      '${stepIndex + 1}',
                      style: TextStyle(
                        fontSize: 10,
                        color: isCompleted ? Colors.white : AppColors.mediumGray,
                      ),
                    ),
                  ),
          );
        }
      }),
    );
  }
}

class _TimerCard extends StatelessWidget {
  final Duration remaining;
  const _TimerCard({required this.remaining});

  @override
  Widget build(BuildContext context) {
    final isUrgent = remaining.inMinutes < 5 && remaining.isNegative == false;
    return Card(
      color: isUrgent ? AppColors.errorRed.withAlpha(20) : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.timer,
              color: isUrgent ? AppColors.errorRed : AppColors.escrowBlue,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Auto-release timer', style: TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    _formatRemainingTime(remaining),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isUrgent ? AppColors.errorRed : AppColors.charcoal,
                    ),
                  ),
                  Text(
                    'Payment will auto-release to vendor after this time',
                    style: TextStyle(fontSize: 11, color: AppColors.mediumGray),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatRemainingTime(Duration d) {
    if (d.isNegative || d == Duration.zero) return 'Auto-releasing now...';
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
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
