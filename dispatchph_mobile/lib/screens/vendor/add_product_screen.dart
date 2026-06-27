import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/app_image.dart';
import '../../widgets/delivery_option_tile.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/supabase_service.dart';

class AddProductScreen extends StatefulWidget {
  const AddProductScreen({super.key});

  @override
  State<AddProductScreen> createState() => _AddProductScreenState();
}

class _AddProductScreenState extends State<AddProductScreen> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _priceController = TextEditingController();
  final _stockController = TextEditingController();
  final _picker = ImagePicker();
  String _category = 'Other';
  String _deliveryType = 'negotiate';
  bool _isLoading = false;
  double _uploadProgress = 0;
  List<XFile> _images = [];
  List<_VariantRow> _variants = [];

  final _categories = ['Food', 'Fashion', 'Electronics', 'Health', 'Home', 'Other'];

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _priceController.dispose();
    _stockController.dispose();
    for (final v in _variants) {
      v.label.dispose();
      v.price.dispose();
      v.stock.dispose();
    }
    super.dispose();
  }

  String _totalSizeText() {
    if (_images.isEmpty) return '';
    int total = 0;
    for (final img in _images) {
      final f = File(img.path);
      if (f.existsSync()) total += f.lengthSync();
    }
    if (total < 1024) return '$total B total';
    if (total < 1024 * 1024) return '${(total / 1024).toStringAsFixed(1)} KB total';
    return '${(total / (1024 * 1024)).toStringAsFixed(1)} MB total';
  }

  bool _anyOverSize() {
    for (final img in _images) {
      if (!StorageService.isUnderSizeLimit(img.path)) return true;
    }
    return false;
  }

  Future<void> _pickImages() async {
    if (_images.length >= 4) {
      _showError('Maximum 4 images allowed');
      return;
    }
    await showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: AppColors.primaryGreen),
              title: const Text('Take Photo'),
              onTap: () async {
                Navigator.pop(context);
                final picked = await _picker.pickImage(
                  source: ImageSource.camera,
                  imageQuality: 70,
                  maxWidth: 1200,
                  maxHeight: 1200,
                );
                if (picked != null) {
                  final compressed = await StorageService.compressImage(picked);
                  setState(() => _images.add(compressed ?? picked));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: AppColors.primaryGreen),
              title: const Text('Choose from Gallery'),
              onTap: () async {
                Navigator.pop(context);
                final picked = await _picker.pickMultiImage(
                  imageQuality: 70,
                  maxWidth: 1200,
                  maxHeight: 1200,
                );
                if (picked.isNotEmpty) {
                  final compressed = await StorageService.compressImages(picked);
                  final remaining = 4 - _images.length;
                  setState(() => _images.addAll(compressed.take(remaining)));
                  if (picked.length > remaining) {
                    _showError('Max 4 images allowed. ${picked.length - remaining} skipped.');
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _removeImage(int index) {
    setState(() => _images.removeAt(index));
  }

  void _addVariant() {
    setState(() => _variants.add(_VariantRow()));
  }

  void _removeVariant(int index) {
    _variants[index].label.dispose();
    _variants[index].price.dispose();
    _variants[index].stock.dispose();
    setState(() => _variants.removeAt(index));
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final price = double.tryParse(_priceController.text.trim()) ?? 0;
    final stock = int.tryParse(_stockController.text.trim()) ?? 0;
    if (name.isEmpty || price <= 0) {
      _showError('Enter product name and valid price');
      return;
    }
    if (stock < 0) {
      _showError('Stock must be 0 or more');
      return;
    }

    setState(() {
      _isLoading = true;
      _uploadProgress = 0;
    });

    final storeId = await AuthService.getStoreId();
    if (storeId.isEmpty) {
      _showError('No store found. Set up your store first.');
      setState(() => _isLoading = false);
      return;
    }

    final vendorId = SupabaseService.auth.currentUser?.id ?? '';

    // Upload images with progress
    List<String> imageUrls = [];
    if (_images.isNotEmpty) {
      final total = _images.length;
      for (int i = 0; i < total; i++) {
        final url = await StorageService.uploadProductImage(_images[i].path, vendorId);
        if (url != null) imageUrls.add(url);
        setState(() => _uploadProgress = (i + 1) / total);
      }
    }

    // Build variants
    final variants = <ProductVariant>[];
    for (int i = 0; i < _variants.length; i++) {
      final v = _variants[i];
      final vPrice = double.tryParse(v.price.text.trim()) ?? 0;
      final vStock = int.tryParse(v.stock.text.trim()) ?? 0;
      if (v.label.text.trim().isNotEmpty && vPrice > 0) {
        String? variantImageUrl;
        if (v.imagePath != null) {
          variantImageUrl = await StorageService.uploadProductImage(v.imagePath!, vendorId);
        }
        variants.add(ProductVariant(
          productId: '',
          label: v.label.text.trim(),
          price: vPrice,
          stock: vStock,
          imageUrl: variantImageUrl,
          sortOrder: i,
        ));
      }
    }

    String? error;
    try {
      error = await context.read<MarketplaceCubit>().addProduct(
        storeId,
        name,
        _descController.text.trim().isEmpty ? null : _descController.text.trim(),
        price,
        _category,
        variants.isEmpty ? stock : 0,
        images: imageUrls,
        variants: variants,
        deliveryType: _deliveryType,
      );
    } catch (e) {
      error = e.toString();
    }

    if (!mounted) return;
    setState(() => _isLoading = false);
    if (error != null) {
      _showError('Failed to save: $error');
      return;
    }
    Navigator.pop(context);
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Product')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Product Details', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Product name', hintText: 'e.g., Fresh Tomatoes'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descController,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Description (optional)', hintText: 'Describe your product'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _priceController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Base Price (\u20A6)',
                hintText: 'e.g., 1500',
                helperText: 'Used if no variants below',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _stockController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Stock quantity',
                hintText: 'e.g., 10',
                helperText: 'Used if no variants below',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
              onChanged: (v) {
                if (v != null) setState(() => _category = v);
              },
            ),
            const SizedBox(height: 24),

            // Delivery Policy Section
            const Text(
              'Delivery Policy',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.primaryGreen),
            ),
            const SizedBox(height: 4),
            Text('How will delivery fee be handled?', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            const SizedBox(height: 12),
            DeliveryOptionTile(
              icon: '🎁',
              title: 'Free Delivery',
              subtitle: 'I cover all delivery costs.\nNo fee charged to buyer.',
              isSelected: _deliveryType == 'free',
              onTap: () => setState(() => _deliveryType = 'free'),
            ),
            const SizedBox(height: 8),
            DeliveryOptionTile(
              icon: '💬',
              title: 'Buyer Pays (Agree in Chat)',
              subtitle: 'Buyer pays full delivery fee.\nAgree the amount in chat.',
              isSelected: _deliveryType == 'negotiate',
              onTap: () => setState(() => _deliveryType = 'negotiate'),
            ),
            const SizedBox(height: 8),
            DeliveryOptionTile(
              icon: '🤝',
              title: 'Split Delivery Fee (Agree in Chat)',
              subtitle: 'You and buyer share the cost.\nAgree the split in chat.',
              isSelected: _deliveryType == 'split',
              onTap: () => setState(() => _deliveryType = 'split'),
            ),
            const SizedBox(height: 24),

            // Product Images Section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Product Images', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                Text('${_images.length}/4', style: const TextStyle(color: AppColors.mediumGray)),
              ],
            ),
            const SizedBox(height: 8),
            if (_images.isNotEmpty) ...[
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _images.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final sizeText = StorageService.getFileSize(_images[i].path);
                    final overSize = !StorageService.isUnderSizeLimit(_images[i].path);
                    return Stack(
                      children: [
                        Column(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: AppImage(
                                source: _images[i].path,
                                width: 100,
                                height: 80,
                                fit: BoxFit.cover,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              sizeText,
                              style: TextStyle(
                                fontSize: 10,
                                color: overSize ? AppColors.errorRed : AppColors.mediumGray,
                              ),
                            ),
                          ],
                        ),
                        Positioned(
                          top: 0,
                          right: 0,
                          child: GestureDetector(
                            onTap: () => _removeImage(i),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close, size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _totalSizeText(),
                  style: TextStyle(
                    fontSize: 11,
                    color: _anyOverSize() ? AppColors.errorRed : AppColors.successGreen,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            GestureDetector(
              onTap: _pickImages,
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.primaryGreen.withAlpha(100), width: 1.5),
                  borderRadius: BorderRadius.circular(12),
                  color: AppColors.primaryGreen.withAlpha(10),
                ),
                child: const Center(
                  child: Column(
                    children: [
                      Icon(Icons.add_photo_alternate, size: 40, color: AppColors.primaryGreen),
                      SizedBox(height: 8),
                      Text('Tap to add photos (max 4)', style: TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.w500)),
                      SizedBox(height: 4),
                      Text('JPEG / PNG \u2022 Max 2MB each \u2022 Auto-compressed', style: TextStyle(color: AppColors.mediumGray, fontSize: 11)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Variants Section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Variants', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                TextButton.icon(
                  onPressed: _addVariant,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
            if (_variants.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Optional: Add size, color, or capacity options with different prices',
                  style: TextStyle(color: AppColors.mediumGray, fontSize: 12),
                ),
              ),
            ...List.generate(_variants.length, (i) {
              final v = _variants[i];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          GestureDetector(
                            onTap: () async {
                              final picked = await _picker.pickImage(
                                source: ImageSource.gallery,
                                imageQuality: 70,
                                maxWidth: 1200,
                                maxHeight: 1200,
                              );
                              if (picked != null) {
                                final compressed = await StorageService.compressImage(picked);
                                setState(() => v.imagePath = (compressed ?? picked).path);
                              }
                            },
                            child: Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: AppColors.lightGray,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: AppColors.mediumGray.withAlpha(80)),
                              ),
                              child: v.imagePath != null
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: AppImage(source: v.imagePath!, fit: BoxFit.cover),
                                    )
                                  : const Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.add_a_photo, size: 20, color: AppColors.mediumGray),
                                        SizedBox(height: 2),
                                        Text('Image', style: TextStyle(fontSize: 9, color: AppColors.mediumGray)),
                                      ],
                                    ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: v.label,
                              decoration: const InputDecoration(
                                labelText: 'Option label',
                                hintText: 'e.g., iPhone 16, 128GB',
                                isDense: true,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18, color: Colors.red),
                            onPressed: () => _removeVariant(i),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: v.price,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Price (\u20A6)',
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: v.stock,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Stock',
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 24),

            // Upload progress bar
            if (_isLoading && _images.isNotEmpty) ...[
              LinearProgressIndicator(value: _uploadProgress),
              const SizedBox(height: 8),
              Text(
                'Uploading images... ${(_uploadProgress * 100).toInt()}%',
                style: const TextStyle(fontSize: 12, color: AppColors.mediumGray),
              ),
              const SizedBox(height: 16),
            ],

            PrimaryButton(
              text: 'Save Product',
              isLoading: _isLoading,
              onPressed: _submit,
              backgroundColor: AppColors.primaryGreen,
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _VariantRow {
  final TextEditingController label = TextEditingController();
  final TextEditingController price = TextEditingController();
  final TextEditingController stock = TextEditingController();
  String? imagePath;
}
