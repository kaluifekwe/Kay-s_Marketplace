class AppUser {
  final String id;
  final String email;
  final String password;
  final String name;
  final String role; // buyer, vendor
  final String? phone;
  final String? nin;
  final String? storeId;
  final DateTime createdAt;

  AppUser({
    required this.id,
    required this.email,
    required this.password,
    required this.name,
    required this.role,
    this.phone,
    this.nin,
    this.storeId,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'password': password,
        'name': name,
        'role': role,
        'phone': phone,
        'nin': nin,
        'store_id': storeId,
        'created_at': createdAt.toIso8601String(),
      };
}
