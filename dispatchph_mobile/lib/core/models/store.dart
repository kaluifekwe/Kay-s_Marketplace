class Store {
  final String id;
  final String vendorId;
  final String name;
  final String? description;
  final String? logoPath;
  final String? address;
  final String? phone;
  final DateTime createdAt;

  Store({
    required this.id,
    required this.vendorId,
    required this.name,
    this.description,
    this.logoPath,
    this.address,
    this.phone,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}
