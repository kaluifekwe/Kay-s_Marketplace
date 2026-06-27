class CartItem {
  final String id;
  final String buyerId;
  final String productId;
  final int quantity;
  final DateTime addedAt;

  CartItem({
    required this.id,
    required this.buyerId,
    required this.productId,
    this.quantity = 1,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();
}
