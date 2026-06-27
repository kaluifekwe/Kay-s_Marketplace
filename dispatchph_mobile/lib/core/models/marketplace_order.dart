import 'dart:convert';

class MarketplaceOrder {
  final String id;
  final String buyerId;
  final String vendorId;
  final String storeId;
  final List<Map<String, dynamic>> items;
  final double total;
  final String status; // paid, shipped, delivered, confirmed, refund_requested, refunded, auto_released
  final String? shippingMethod;
  final String? trackingRef;
  final DateTime? paidAt;
  final DateTime? shippedAt;
  final DateTime? deliveredAt;
  final DateTime? confirmedAt;
  final DateTime? autoReleaseAt;
  final DateTime createdAt;

  MarketplaceOrder({
    required this.id,
    required this.buyerId,
    required this.vendorId,
    required this.storeId,
    required this.items,
    required this.total,
    this.status = 'paid',
    this.shippingMethod,
    this.trackingRef,
    this.paidAt,
    this.shippedAt,
    this.deliveredAt,
    this.confirmedAt,
    this.autoReleaseAt,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  String get itemsJson => jsonEncode(items);

  String get statusLabel {
    switch (status) {
      case 'paid':
        return 'Payment Held in Escrow';
      case 'shipped':
        return 'Shipped';
      case 'delivered':
        return 'Delivered — Confirm within 24h';
      case 'confirmed':
        return 'Completed — Payment Released';
      case 'refund_requested':
        return 'Refund Requested';
      case 'refunded':
        return 'Refunded';
      case 'auto_released':
        return 'Auto-Released to Vendor';
      default:
        return status;
    }
  }
}
