import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/app_image.dart';
import '../../bloc_exports.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/supabase_service.dart';

class _VariantRow {
  final TextEditingController label;
  final TextEditingController price;
  final TextEditingController stock;
  String? existingId;
  String? existingImageUrl;
  String? imagePath;
  bool deleted = false;

  _VariantRow({String? id, String? labelVal, String? priceVal, String? stockVal, String? imageUrl})
      : label = TextEditingController(text: labelVal ?? ''),
        price = TextEditingController(text: priceVal ?? ''),
        stock = TextEditingController(text: stockVal ?? '0'),
        existingId = id,
        existingImageUrl = imageUrl;

  void dispose() {
    label.dispose();
    price.dispose();
    stock.dispose();
  }
}

class EditProductScreen extends StatefulWidget {
  final dynamic product;
  const EditProductScreen({super.key, required this.product});

  @override
  State<EditProductScreen> createState() => _EditProductScreenState();
}

class _EditProductScreenState extends State<EditProductScreen> {
  late TextEditingController _nameController;
  late TextEditingController _descController;
  late TextEditingController _priceController;
  late TextEditingController _stockController;
  late String _category;
  late String _deliveryType;
  final _picker = ImagePicker();
  bool _isLoading = false;
  late List<String> _imagePaths;
  List<_VariantRow> _variants = [];
  bool _variantsLoaded = false;

  final _categories = ['Food', 'Fashion', 'Electronics', 'Health', 'Home', 'Other'];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.product.name);
    _descController = TextEditingController(text: widget.product.description ?? '');
    _priceController = TextEditingController(text: widget.product.price.toString());
    _stockController = TextEditingController(text: widget.product.stock.toString());
    _category = widget.product.category ?? 'Other';
    _deliveryType = 'courier'; // courier-only; fee calculated at checkout
    final decoded = jsonDecode(widget.product.images ?? '[]');
    _imagePaths = List<String>.from(decoded);
    _loadVariants();
  }

  Future<void> _loadVariants() async {
    final variants = await context.read<MarketplaceCubit>().loadVariants(widget.product.id, forceRefresh: true);
    if (mounted) {
      setState(() {
        _variants = variants.map((v) => _VariantRow(
          id: v.id,
          labelVal: v.label,
          priceVal: v.price.toString(),
          stockVal: v.stock.toString(),
          imageUrl: v.imageUrl,
        )).toList();
        _variantsLoaded = true;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _priceController.dispose();
    _stockController.dispose();
    for (final v in _variants) {
      v.dispose();
    }
    super.dispose();
  }

  void _addVariant() {
    setState(() => _variants.add(_VariantRow()));
  }

  void _removeVariant(int index) {
    final v = _variants[index];
    if (v.existingId != null) {
      v.deleted = true;
    } else {
      v.dispose();
      _variants.removeAt(index);
    }
    setState(() {});
  }

  Future<void> _pickImages() async {
    if (_imagePaths.length >= 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum 4 images allowed')),
      );
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
                final picked = await _picker.pickImage(source: ImageSource.camera, imageQuality: 75);
                if (picked != null && _imagePaths.length < 4) {
                  setState(() => _imagePaths.add(picked.path));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: AppColors.primaryGreen),
              title: const Text('Choose from Gallery'),
              onTap: () async {
                Navigator.pop(context);
                final picked = await _picker.pickMultiImage(imageQuality: 75);
                if (picked.isNotEmpty) {
                  final remaining = 4 - _imagePaths.length;
                  if (picked.length > remaining) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Only $remaining more image(s) allowed')),
                      );
                    }
                  }
                  setState(() => _imagePaths.addAll(picked.take(remaining).map((x) => x.path)));
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _removeImage(int index) {
    setState(() => _imagePaths.removeAt(index));
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final price = double.tryParse(_priceController.text.trim()) ?? 0;
    final stock = int.tryParse(_stockController.text.trim()) ?? 0;
    if (name.isEmpty || price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter product name and valid price')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await context.read<MarketplaceCubit>().updateProduct(
        widget.product.id,
        name,
        _descController.text.trim().isEmpty ? null : _descController.text.trim(),
        price,
        _category,
        stock,
        deliveryType: _deliveryType,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update product: $e')));
      }
      setState(() => _isLoading = false);
      return;
    }

    final vendorId = SupabaseService.auth.currentUser?.id ?? '';
    final existingUrls = <String>[];
    final newPaths = <String>[];
    for (final p in _imagePaths) {
      if (p.startsWith('http')) {
        existingUrls.add(p);
      } else {
        newPaths.add(p);
      }
    }
    final uploadedUrls = await StorageService.uploadProductImages(newPaths, vendorId);
    final allImages = [...existingUrls, ...uploadedUrls];
    await context.read<MarketplaceCubit>().updateProductImages(widget.product.id, allImages);

    // Save variants
    final cubit = context.read<MarketplaceCubit>();
    for (final v in _variants) {
      if (v.deleted && v.existingId != null) {
        await cubit.deleteVariant(v.existingId!, widget.product.id);
      } else if (!v.deleted && v.existingId == null) {
        final label = v.label.text.trim();
        final vPrice = double.tryParse(v.price.text.trim()) ?? 0;
        final vStock = int.tryParse(v.stock.text.trim()) ?? 0;
        if (label.isNotEmpty && vPrice > 0) {
          String? variantImageUrl;
          if (v.imagePath != null) {
            variantImageUrl = await StorageService.uploadProductImage(v.imagePath!, vendorId);
          }
          await cubit.addVariant(widget.product.id, label, vPrice, vStock, imageUrl: variantImageUrl);
        }
      } else if (!v.deleted && v.existingId != null && v.imagePath != null) {
        final variantImageUrl = await StorageService.uploadProductImage(v.imagePath!, vendorId);
        if (variantImageUrl != null) {
          await SupabaseService.client.from('product_variants').update({
            'image_url': variantImageUrl,
          }).eq('id', v.existingId!);
        }
      }
    }

    if (!mounted) return;
    setState(() => _isLoading = false);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final activeVariants = _variants.where((v) => !v.deleted).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Product')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Product name'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descController,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _priceController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Price (\u20A6)'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _stockController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Stock',
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
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.lightGray,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Text('🚚', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Delivery is by courier. The exact fee is calculated at checkout. '
                      'If no courier covers the route, the buyer arranges delivery with you in chat.',
                      style: TextStyle(fontSize: 12, color: Colors.grey[700], height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Images (${_imagePaths.length}/4)', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            if (_imagePaths.isNotEmpty)
              SizedBox(
                height: 100,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _imagePaths.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: AppImage(
                          source: _imagePaths[i],
                          width: 100,
                          height: 100,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
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
                  ),
                ),
              ),
            const SizedBox(height: 8),
            if (_imagePaths.length < 4)
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
                        Text('Tap to add more images', style: TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 24),

            // Variants Section
            if (_variantsLoaded) ...[
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
              if (activeVariants.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Optional: Add size, color, or capacity options with different prices',
                    style: TextStyle(color: AppColors.mediumGray, fontSize: 12),
                  ),
                ),
              ...List.generate(_variants.length, (i) {
                final v = _variants[i];
                if (v.deleted) return const SizedBox.shrink();
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
                                    : v.existingImageUrl != null
                                        ? ClipRRect(
                                            borderRadius: BorderRadius.circular(8),
                                            child: AppImage(source: v.existingImageUrl!, fit: BoxFit.cover),
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
            ],

            const SizedBox(height: 32),
            PrimaryButton(
              text: 'Update Product',
              isLoading: _isLoading,
              onPressed: _submit,
              backgroundColor: AppColors.primaryGreen,
            ),
          ],
        ),
      ),
    );
  }
}
