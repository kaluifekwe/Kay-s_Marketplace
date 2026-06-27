class DeliveryOrder {
  final String id;
  final String senderId;
  final String? riderId;
  final String pickupAddress;
  final double pickupLat;
  final double pickupLng;
  final String dropoffAddress;
  final double dropoffLat;
  final double dropoffLng;
  final String packageDesc;
  final String packageType;
  final String status; // pending, accepted, picked_up, delivered, cancelled
  final double fare;
  final String? podPhotoUrl;
  final int? senderRating;
  final DateTime createdAt;
  final double? riderLat;
  final double? riderLng;

  DeliveryOrder({
    required this.id,
    required this.senderId,
    this.riderId,
    required this.pickupAddress,
    required this.pickupLat,
    required this.pickupLng,
    required this.dropoffAddress,
    required this.dropoffLat,
    required this.dropoffLng,
    required this.packageDesc,
    required this.packageType,
    required this.status,
    required this.fare,
    this.podPhotoUrl,
    this.senderRating,
    required this.createdAt,
    this.riderLat,
    this.riderLng,
  });

  factory DeliveryOrder.fromJson(Map<String, dynamic> json) {
    return DeliveryOrder(
      id: json['id'] ?? '',
      senderId: json['sender_id'] ?? '',
      riderId: json['rider_id'],
      pickupAddress: json['pickup_address'] ?? '',
      pickupLat: (json['pickup_lat'] ?? 0).toDouble(),
      pickupLng: (json['pickup_lng'] ?? 0).toDouble(),
      dropoffAddress: json['dropoff_address'] ?? '',
      dropoffLat: (json['dropoff_lat'] ?? 0).toDouble(),
      dropoffLng: (json['dropoff_lng'] ?? 0).toDouble(),
      packageDesc: json['package_desc'] ?? '',
      packageType: json['package_type'] ?? 'other',
      status: json['status'] ?? 'pending',
      fare: (json['fare'] ?? 0).toDouble(),
      podPhotoUrl: json['pod_photo_url'],
      senderRating: json['sender_rating'],
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      riderLat: json['rider_lat']?.toDouble(),
      riderLng: json['rider_lng']?.toDouble(),
    );
  }

  String get statusLabel {
    switch (status) {
      case 'pending': return 'Looking for a rider...';
      case 'accepted': return 'Rider on the way';
      case 'picked_up': return 'Package picked up';
      case 'delivered': return 'Delivered';
      case 'cancelled': return 'Cancelled';
      default: return status;
    }
  }
}
