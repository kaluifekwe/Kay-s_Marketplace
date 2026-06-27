import 'dart:convert';

class Product {
  final String id;
  final String storeId;
  final String name;
  final String? description;
  final double price;
  final List<String> images;
  final String? category;
  final int stock;
  final DateTime createdAt;

  Product({
    required this.id,
    required this.storeId,
    required this.name,
    this.description,
    required this.price,
    List<String>? images,
    this.category,
    this.stock = 0,
    DateTime? createdAt,
  })  : images = images ?? [],
        createdAt = createdAt ?? DateTime.now();

  String get imagesJson => jsonEncode(images);
}
