class AppUser {
  final String id;
  final String phone;
  final String name;
  final String userType; // 'shop' or 'individual'
  final String? shopName;
  final String? defaultPickupAddress;
  final double? defaultPickupLat;
  final double? defaultPickupLng;
  final double walletBalance;

  AppUser({
    required this.id,
    required this.phone,
    required this.name,
    required this.userType,
    this.shopName,
    this.defaultPickupAddress,
    this.defaultPickupLat,
    this.defaultPickupLng,
    this.walletBalance = 0,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] ?? '',
      phone: json['phone'] ?? '',
      name: json['name'] ?? '',
      userType: json['user_type'] ?? 'individual',
      shopName: json['shop_name'],
      defaultPickupAddress: json['default_pickup_address'],
      defaultPickupLat: json['default_pickup_lat']?.toDouble(),
      defaultPickupLng: json['default_pickup_lng']?.toDouble(),
      walletBalance: (json['wallet_balance'] ?? 0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'phone': phone,
      'name': name,
      'user_type': userType,
      'shop_name': shopName,
      'default_pickup_address': defaultPickupAddress,
      'default_pickup_lat': defaultPickupLat,
      'default_pickup_lng': defaultPickupLng,
      'wallet_balance': walletBalance,
    };
  }
}
