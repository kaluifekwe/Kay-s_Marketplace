import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import 'order_detail_screen.dart';

String orderStatusLabel(String status) {
  switch (status) {
    case 'paid': return 'Payment Held in Escrow';
    case 'shipped': return 'Shipped — Awaiting Delivery';
    case 'delivered': return 'Delivered — Confirm within 24h';
    case 'confirmed': return 'Completed — Payment Released';
    case 'refund_requested': return 'Refund Requested';
    case 'refunded': return 'Refunded';
    case 'cancelled': return 'Cancelled — Refunded';
    case 'auto_released': return 'Auto-Released to Vendor';
    default: return status;
  }
}

Color orderStatusColor(String status) {
  switch (status) {
    case 'paid': return AppColors.escrowBlue;
    case 'shipped': return AppColors.primaryBlue;
    case 'delivered': return AppColors.warningOrange;
    case 'confirmed': return AppColors.primaryGreen;
    case 'refund_requested': return AppColors.refundOrange;
    case 'refunded': return AppColors.refundOrange;
    case 'cancelled': return AppColors.mediumGray;
    case 'auto_released': return AppColors.primaryGreen;
    default: return AppColors.mediumGray;
  }
}

IconData orderStatusIcon(String status) {
  switch (status) {
    case 'paid': return Icons.account_balance;
    case 'shipped': return Icons.local_shipping;
    case 'delivered': return Icons.inventory;
    case 'confirmed': return Icons.check_circle;
    case 'refund_requested': return Icons.money_off;
    case 'refunded': return Icons.replay;
    case 'cancelled': return Icons.cancel;
    case 'auto_released': return Icons.check_circle_outline;
    default: return Icons.receipt;
  }
}

bool _isActiveOrder(String status) {
  return !['confirmed', 'auto_released', 'refunded', 'cancelled'].contains(status);
}

bool _isDeliveredOrder(String status) {
  return ['confirmed', 'auto_released', 'refunded', 'cancelled'].contains(status);
}

class BuyerOrdersScreen extends StatefulWidget {
  const BuyerOrdersScreen({super.key});

  @override
  State<BuyerOrdersScreen> createState() => _BuyerOrdersScreenState();
}

class _BuyerOrdersScreenState extends State<BuyerOrdersScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Timer? _refreshTimer;
  OrderCubit? _orderCubit;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadOrders();
    _subscribeToOrders();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) => _loadOrders());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _orderCubit ??= context.read<OrderCubit>();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _orderCubit?.unsubscribeOrders();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final buyerId = prefs.getString('auth_user_id') ?? '';
    if (buyerId.isNotEmpty) {
      context.read<OrderCubit>().loadBuyerOrders(buyerId);
    }
  }

  void _subscribeToOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final buyerId = prefs.getString('auth_user_id') ?? '';
    if (buyerId.isNotEmpty) {
      context.read<OrderCubit>().subscribeToBuyerOrders(buyerId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Orders'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.primaryGreen,
          labelColor: AppColors.primaryGreen,
          unselectedLabelColor: AppColors.mediumGray,
          tabs: const [
            Tab(text: 'Active'),
            Tab(text: 'Delivered'),
          ],
        ),
      ),
      body: BlocBuilder<OrderCubit, OrderState>(
        builder: (context, state) {
          if (state.isLoading) return const Center(child: CircularProgressIndicator());

          final activeOrders = state.buyerOrders.where((o) => _isActiveOrder(o.status)).toList();
          final deliveredOrders = state.buyerOrders.where((o) => _isDeliveredOrder(o.status)).toList();

          return RefreshIndicator(
            onRefresh: _loadOrders,
            child: TabBarView(
              controller: _tabController,
              children: [
                _OrdersList(orders: activeOrders, emptyMessage: 'No active orders'),
                _OrdersList(orders: deliveredOrders, emptyMessage: 'No delivered orders yet'),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _OrdersList extends StatelessWidget {
  final List orders;
  final String emptyMessage;
  const _OrdersList({required this.orders, required this.emptyMessage});

  @override
  Widget build(BuildContext context) {
    if (orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long, size: 64, color: AppColors.mediumGray),
            const SizedBox(height: 16),
            Text(emptyMessage, style: const TextStyle(color: AppColors.mediumGray)),
          ],
        ),
      );
    }

    final format = NumberFormat('#,##0');
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: orders.length,
      itemBuilder: (_, i) {
        final order = orders[i];
        final status = orderStatusLabel(order.status);
        final color = orderStatusColor(order.status);
        final icon = orderStatusIcon(order.status);

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: color.withAlpha(25),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            title: Text('Order #${order.id.substring(0, 8)}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text('\u20A6${format.format(order.totalWithDelivery ?? order.total)}',
                    style: const TextStyle(color: AppColors.primaryGreen)),
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: order.id)),
            ),
          ),
        );
      },
    );
  }
}
