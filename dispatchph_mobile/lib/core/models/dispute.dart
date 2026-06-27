class Dispute {
  final String id;
  final String orderId;
  final String raisedBy;
  final String reason;
  final String status; // open, resolved, rejected
  final DateTime? resolvedAt;
  final DateTime createdAt;

  Dispute({
    required this.id,
    required this.orderId,
    required this.raisedBy,
    required this.reason,
    this.status = 'open',
    this.resolvedAt,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}
