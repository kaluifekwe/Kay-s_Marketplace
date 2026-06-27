class Rider {
  final String id;
  final String phone;
  final String name;
  final bool isVerified;
  final bool isOnline;
  final double? currentLat;
  final double? currentLng;
  final int totalDeliveries;
  final double rating;
  final int ratingCount;

  Rider({
    required this.id,
    required this.phone,
    required this.name,
    this.isVerified = false,
    this.isOnline = false,
    this.currentLat,
    this.currentLng,
    this.totalDeliveries = 0,
    this.rating = 5.0,
    this.ratingCount = 0,
  });

  factory Rider.fromJson(Map<String, dynamic> json) {
    return Rider(
      id: json['id'] ?? '',
      phone: json['phone'] ?? '',
      name: json['name'] ?? '',
      isVerified: json['is_verified'] ?? false,
      isOnline: json['is_online'] ?? false,
      currentLat: json['current_lat']?.toDouble(),
      currentLng: json['current_lng']?.toDouble(),
      totalDeliveries: json['total_deliveries'] ?? 0,
      rating: (json['rating'] ?? 5.0).toDouble(),
      ratingCount: json['rating_count'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'phone': phone,
      'name': name,
      'is_verified': isVerified,
      'is_online': isOnline,
      'current_lat': currentLat,
      'current_lng': currentLng,
      'total_deliveries': totalDeliveries,
      'rating': rating,
      'rating_count': ratingCount,
    };
  }
}
