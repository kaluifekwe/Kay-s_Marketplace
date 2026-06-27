class Chat {
  final String id;
  final String orderId;
  final String buyerId;
  final String vendorId;
  final DateTime createdAt;

  Chat({
    required this.id,
    required this.orderId,
    required this.buyerId,
    required this.vendorId,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}
