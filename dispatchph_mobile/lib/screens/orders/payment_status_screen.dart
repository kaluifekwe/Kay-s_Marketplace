import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/payment_service.dart';

class PaymentStatusScreen extends StatefulWidget {
  final String orderId;

  const PaymentStatusScreen({super.key, required this.orderId});

  @override
  State<PaymentStatusScreen> createState() => _PaymentStatusScreenState();
}

class _PaymentStatusScreenState extends State<PaymentStatusScreen> {
  Order? _order;
  List<Map<String, dynamic>> _transactions = [];
  Timer? _refreshTimer;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadData();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadData());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;

    try {
      // Load order from cubit
      final cubit = context.read<OrderCubit>();
      final buyerOrders = cubit.state.buyerOrders;
      final vendorOrders = cubit.state.vendorOrders;
      final allOrders = [...buyerOrders, ...vendorOrders];
      final order = allOrders.where((o) => o.id == widget.orderId).firstOrNull;

      // Load transactions
      final transactions = await PaymentService.getTransactions(widget.orderId);

      if (mounted) {
        setState(() {
          _order = order;
          _transactions = transactions;
        });

        // Calculate remaining auto-release time
        if (order?.autoReleaseAt != null && order?.status == 'shipped') {
          final remaining = order!.autoReleaseAt!.difference(DateTime.now());
          _remaining = remaining.isNegative ? Duration.zero : remaining;
        }
      }
    } catch (e) {
      print('[PaymentStatus] _loadData error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment Status'),
        backgroundColor: AppColors.primaryGreen,
        foregroundColor: Colors.white,
      ),
      body: _order == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  // Status card
                  _buildStatusCard(),
                  const SizedBox(height: 20),

                  // Auto-release timer
                  if (_order!.status == 'shipped') ...[
                    _buildTimerCard(),
                    const SizedBox(height: 20),
                  ],

                  // Order details
                  _buildOrderDetails(format),
                  const SizedBox(height: 20),

                  // Transaction history
                  if (_transactions.isNotEmpty) ...[
                    const Text('Transaction History',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    ..._transactions.map((tx) => _buildTransactionTile(tx)),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildStatusCard() {
    Color statusColor;
    IconData statusIcon;
    String title;
    String subtitle;

    switch (_order!.status) {
      case 'paid':
        statusColor = AppColors.escrowBlue;
        statusIcon = Icons.lock;
        title = 'Payment Confirmed';
        subtitle = 'Funds held in escrow';
        break;
      case 'shipped':
        statusColor = AppColors.primaryGreen;
        statusIcon = Icons.local_shipping;
        title = 'Order Shipped';
        subtitle = 'Confirm delivery within 24h';
        break;
      case 'confirmed':
        statusColor = AppColors.successGreen;
        statusIcon = Icons.check_circle;
        title = 'Delivery Confirmed';
        subtitle = 'Payment released to vendor';
        break;
      case 'auto_released':
        statusColor = AppColors.successGreen;
        statusIcon = Icons.timer_off;
        title = 'Auto-Released';
        subtitle = 'Payment automatically released';
        break;
      case 'refunded':
        statusColor = AppColors.mediumGray;
        statusIcon = Icons.replay;
        title = 'Refunded';
        subtitle = 'Payment returned to your account';
        break;
      default:
        statusColor = AppColors.mediumGray;
        statusIcon = Icons.info_outline;
        title = _order!.status.toUpperCase();
        subtitle = '';
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: statusColor.withAlpha(15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withAlpha(40), width: 2),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: statusColor.withAlpha(20),
              shape: BoxShape.circle,
            ),
            child: Icon(statusIcon, color: statusColor, size: 40),
          ),
          const SizedBox(height: 16),
          Text(title, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: statusColor)),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: AppColors.mediumGray)),
        ],
      ),
    );
  }

  Widget _buildTimerCard() {
    final format = NumberFormat('#,##0');
    final hours = _remaining.inHours;
    final minutes = _remaining.inMinutes.remainder(60);
    final seconds = _remaining.inSeconds.remainder(60);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.escrowBlue.withAlpha(10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.escrowBlue.withAlpha(30)),
      ),
      child: Column(
        children: [
          const Text('Auto-Release Countdown',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Text(
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
            style: const TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.bold,
              color: AppColors.escrowBlue,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Payment will be released to vendor if you don\'t confirm delivery',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderDetails(NumberFormat format) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Order Details', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const Divider(),
            _detailRow('Order ID', '#${_order!.id.substring(0, 8)}'),
            _detailRow('Amount', '\u20A6${format.format(_order!.total)}'),
            _detailRow('Status', _order!.status.toUpperCase()),
            if (_order!.paidAt != null)
              _detailRow('Paid', DateFormat('MMM d, y • h:mm a').format(_order!.paidAt!)),
            if (_order!.shippedAt != null)
              _detailRow('Shipped', DateFormat('MMM d, y • h:mm a').format(_order!.shippedAt!)),
            if (_order!.confirmedAt != null)
              _detailRow('Confirmed', DateFormat('MMM d, y • h:mm a').format(_order!.confirmedAt!)),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppColors.mediumGray)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildTransactionTile(Map<String, dynamic> tx) {
    Color typeColor;
    IconData typeIcon;
    String typeLabel;

    switch (tx['type']) {
      case 'payment':
        typeColor = AppColors.primaryGreen;
        typeIcon = Icons.payment;
        typeLabel = 'Payment';
        break;
      case 'release':
        typeColor = AppColors.escrowBlue;
        typeIcon = Icons.send;
        typeLabel = 'Release';
        break;
      case 'refund':
        typeColor = AppColors.warningOrange;
        typeIcon = Icons.replay;
        typeLabel = 'Refund';
        break;
      default:
        typeColor = AppColors.mediumGray;
        typeIcon = Icons.receipt_long;
        typeLabel = tx['type'] ?? 'Unknown';
    }

    final statusColor = tx['status'] == 'success'
        ? AppColors.successGreen
        : tx['status'] == 'pending'
            ? AppColors.warningOrange
            : AppColors.errorRed;

    final format = NumberFormat('#,##0');
    final amount = (tx['amount'] as num?)?.toDouble() ?? 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: typeColor.withAlpha(20),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(typeIcon, color: typeColor, size: 20),
        ),
        title: Text(typeLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          tx['paystack_reference'] ?? '',
          style: const TextStyle(fontSize: 11, color: AppColors.mediumGray),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('\u20A6${format.format(amount)}',
                style: TextStyle(fontWeight: FontWeight.bold, color: typeColor)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withAlpha(20),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(tx['status'] ?? '',
                  style: TextStyle(fontSize: 10, color: statusColor, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}
