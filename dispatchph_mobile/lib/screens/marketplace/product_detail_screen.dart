import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_image.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/share_service.dart';
import '../kyc/kyc_screen.dart';
import 'vendor_store_screen.dart';
import '../chat/chat_screen.dart';
import '../orders/checkout_screen.dart';

class ProductDetailScreen extends StatefulWidget {
  final dynamic product;
  const ProductDetailScreen({super.key, required this.product});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  List<ProductVariant> _variants = [];
  ProductVariant? _selectedVariant;
  bool _loadingVariants = true;
  int _currentImageIndex = 0;
  final _pageController = PageController();

  /// Image list for the carousel — variant images if available, else product images
  List<String> _carouselImages = [];

  /// Maps image URL → variant for quick lookup on swipe
  final Map<String, ProductVariant> _imageToVariant = {};

  @override
  void initState() {
    super.initState();
    _carouselImages = widget.product.imageList;
    final cached = context.read<MarketplaceCubit>().state.variants[widget.product.id];
    if (cached != null && cached.isNotEmpty) {
      _variants = cached;
      _selectedVariant = cached.first;
      _loadingVariants = false;
      _buildImageToVariantMap();
    }
    _loadVariants();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _buildImageToVariantMap() {
    _imageToVariant.clear();
    final variantImages = <String>[];
    for (final v in _variants) {
      if (v.imageUrl != null && v.imageUrl!.isNotEmpty) {
        variantImages.add(v.imageUrl!);
        _imageToVariant[v.imageUrl!] = v;
      }
    }
    if (variantImages.isNotEmpty) {
      _carouselImages = variantImages;
    }
  }

  Future<void> _loadVariants() async {
    // Force a fresh fetch so newly added/edited variants always show, rather
    // than a stale cached list from earlier in the session.
    final variants = await context.read<MarketplaceCubit>().loadVariants(widget.product.id, forceRefresh: true);
    if (!mounted) return;

    if (variants.isNotEmpty && mounted) {
      setState(() {
        _variants = variants;
        _selectedVariant ??= variants.first;
        _loadingVariants = false;
      });
      _buildImageToVariantMap();
    } else {
      setState(() => _loadingVariants = false);
    }
  }

  void _onPageChanged(int index) {
    setState(() => _currentImageIndex = index);
    // Bidirectional: swiping image selects variant
    final imageUrl = _carouselImages[index];
    final variant = _imageToVariant[imageUrl];
    if (variant != null && variant.id != _selectedVariant?.id) {
      setState(() => _selectedVariant = variant);
    }
  }

  void _selectVariant(ProductVariant variant) {
    setState(() => _selectedVariant = variant);
    // Bidirectional: tapping chip jumps carousel to variant image
    if (variant.imageUrl != null) {
      final index = _carouselImages.indexOf(variant.imageUrl!);
      if (index >= 0 && index != _currentImageIndex) {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  bool get _isAvailableInState {
    final buyerState = context.read<MarketplaceCubit>().state.buyerState;
    final vendorState = widget.product.vendorState as String?;
    return buyerState == null || vendorState == null || vendorState == buyerState;
  }

  double get _displayPrice {
    if (_selectedVariant != null) return _selectedVariant!.price;
    return widget.product.price;
  }

  int get _displayStock {
    if (_selectedVariant != null) return _selectedVariant!.stock;
    return widget.product.stock;
  }

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0');
    final images = _carouselImages;
    final hasImages = images.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Product Details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share',
            onPressed: () {
              final imgs = widget.product.imageList;
              ShareService.shareProduct(
                productId: widget.product.id,
                name: widget.product.name,
                price: widget.product.price,
                imageUrl: imgs.isNotEmpty ? imgs.first : null,
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image carousel
            Container(
              height: 300,
              width: double.infinity,
              color: AppColors.lightGray,
              child: hasImages
                  ? Stack(
                      children: [
                        PageView(
                          controller: _pageController,
                          onPageChanged: _onPageChanged,
                          children: images.map((url) => AppImage(
                            source: url,
                            fit: BoxFit.cover,
                            width: double.infinity,
                          )).toList(),
                        ),
                        if (images.length > 1)
                          Positioned(
                            bottom: 8,
                            left: 0,
                            right: 0,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: List.generate(images.length, (i) {
                                return Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 3),
                                  width: _currentImageIndex == i ? 10 : 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _currentImageIndex == i ? AppColors.primaryGreen : Colors.grey.shade400,
                                  ),
                                );
                              }),
                            ),
                          ),
                        if (images.length > 1)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${_currentImageIndex + 1} / ${images.length}',
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ),
                          ),
                      ],
                    )
                  : const Center(
                      child: Icon(Icons.image, size: 64, color: AppColors.mediumGray),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.product.name, style: Theme.of(context).textTheme.headlineMedium),
                  if (!_isAvailableInState) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.errorRed.withAlpha(20),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.errorRed.withAlpha(60)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.location_off, size: 16, color: AppColors.errorRed),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'This vendor is in ${widget.product.vendorState}. You can only purchase from vendors in your own state.',
                              style: const TextStyle(fontSize: 12, color: AppColors.errorRed),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '\u20A6${format.format(_displayPrice)}',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryGreen,
                    ),
                  ),
                  if (_displayStock > 0) ...[
                    const SizedBox(height: 4),
                    Text('$_displayStock in stock', style: const TextStyle(color: AppColors.successGreen)),
                  ] else ...[
                    const SizedBox(height: 4),
                    const Text('Out of stock', style: TextStyle(color: AppColors.errorRed)),
                  ],

                  // Variant selector
                  if (_loadingVariants)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  if (!_loadingVariants && _variants.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Text('Select option', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _variants.map((v) {
                        final selected = _selectedVariant?.id == v.id;
                        return ChoiceChip(
                          label: Text('${v.label} - \u20A6${format.format(v.price)}'),
                          selected: selected,
                          onSelected: v.stock > 0 ? (_) => _selectVariant(v) : null,
                          selectedColor: AppColors.primaryGreen.withAlpha(40),
                          disabledColor: Colors.grey.shade200,
                          avatar: v.imageUrl != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: AppImage(source: v.imageUrl!, width: 24, height: 24, fit: BoxFit.cover),
                                )
                              : v.stock <= 0
                                  ? const Icon(Icons.close, size: 14, color: AppColors.errorRed)
                                  : null,
                        );
                      }).toList(),
                    ),
                  ],

                  const SizedBox(height: 16),
                  _buildDeliveryInfo(context),
                  if (widget.product.description != null && widget.product.description!.isNotEmpty) ...[
                    const Text('Description', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(widget.product.description!, style: const TextStyle(fontSize: 15, height: 1.5, color: AppColors.charcoal)),
                    const SizedBox(height: 16),
                    const Divider(),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.store, color: AppColors.mediumGray),
                      const SizedBox(width: 8),
                      Text('Sold by', style: TextStyle(color: AppColors.mediumGray)),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => VendorStoreScreen(storeId: widget.product.storeId),
                          ),
                        ),
                        child: const Text(
                          'View Store',
                          style: TextStyle(
                            color: AppColors.primaryGreen,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Single-product express checkout: adds this item then checks out
              // ONLY it, leaving any other cart items untouched.
              if (_isAvailableInState && _displayStock > 0) ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _handleBuyNow(context),
                    icon: const Icon(Icons.flash_on),
                    label: const Text('Buy Now'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.riderYellow,
                      foregroundColor: AppColors.charcoal,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _displayStock > 0 ? () => _handleAddToCart(context) : null,
                      icon: Icon(_isAvailableInState ? Icons.shopping_cart : Icons.lock),
                      label: Text(
                        _displayStock == 0
                            ? 'Out of Stock'
                            : _isAvailableInState
                                ? 'Add to Cart'
                                : 'Not Available',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryGreen,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey.shade300,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _contactVendor(context),
                      icon: const Icon(Icons.chat),
                      label: const Text('Contact'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primaryGreen,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleAddToCart(BuildContext context) async {
    if (!_isAvailableInState) {
      final vendorState = widget.product.vendorState as String?;
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.location_off, color: AppColors.errorRed, size: 48),
          title: const Text('Not Available in Your State'),
          content: Text(
            'This product is sold by a vendor in $vendorState. '
            'For now, you can only buy from vendors in your own state.',
            textAlign: TextAlign.center,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: Text('Find in $vendorState', style: const TextStyle(color: AppColors.primaryGreen)),
            ),
          ],
        ),
      );
      return;
    }
    await _addToCart(context);
  }

  /// Express single-product checkout. Adds this item (awaited so checkout sees
  /// it), then opens a checkout scoped to ONLY this product — other cart items
  /// are left untouched.
  Future<void> _handleBuyNow(BuildContext context) async {
    if (!_isAvailableInState) {
      await _handleAddToCart(context); // shows the "not available in your state" dialog
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final buyerId = prefs.getString('auth_user_id') ?? '';
    if (buyerId.isEmpty) return;
    await context.read<CartCubit>().addItem(
          buyerId,
          widget.product.id,
          variantLabel: _selectedVariant?.label,
          variantPrice: _selectedVariant?.price,
        );
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CheckoutScreen(onlyProductId: widget.product.id)),
    );
  }

  Widget _deliveryInfoRow({
    required IconData icon,
    required Color iconColor,
    required String text,
    Color? textColor,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 13, color: textColor ?? AppColors.charcoal)),
        ),
      ],
    );
  }

  Widget _buildDeliveryInfo(BuildContext context) {
    final deliveryType = widget.product.deliveryType as String? ?? 'negotiate';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('🚚 Delivery Information', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 10),
          // Courier (Shipbubble) is the default path for paid delivery; the live
          // fee is only known once the buyer picks a courier at checkout.
          if (deliveryType != 'free') ...[
            _deliveryInfoRow(
              icon: Icons.local_shipping,
              iconColor: AppColors.primaryGreen,
              text: 'Courier delivery available — exact fee calculated at checkout',
            ),
            const SizedBox(height: 10),
          ],
          if (deliveryType == 'free')
            _deliveryInfoRow(
              icon: Icons.check_circle,
              iconColor: AppColors.primaryGreen,
              text: 'Free delivery — vendor covers all costs',
              textColor: AppColors.primaryGreen,
            ),
          if (deliveryType == 'negotiate')
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _deliveryInfoRow(
                  icon: Icons.chat_bubble_outline,
                  iconColor: Colors.orange[700]!,
                  text: 'Delivery fee agreed in chat',
                ),
                const SizedBox(height: 4),
                Text(
                  'Chat with vendor to agree on delivery fee before ordering.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => _contactVendor(context),
                  icon: const Icon(Icons.chat, size: 16, color: AppColors.primaryGreen),
                  label: const Text('Chat with Vendor', style: TextStyle(color: AppColors.primaryGreen)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.primaryGreen),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          if (deliveryType == 'split')
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _deliveryInfoRow(
                  icon: Icons.handshake,
                  iconColor: Colors.blue[700]!,
                  text: 'Delivery fee shared with vendor',
                ),
                const SizedBox(height: 4),
                Text(
                  'Chat with vendor to agree on the delivery cost split.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => _contactVendor(context),
                  icon: Icon(Icons.chat, size: 16, color: Colors.blue[700]),
                  label: Text('Chat with Vendor', style: TextStyle(color: Colors.blue[700])),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.blue[700]!),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.lock_outline, size: 13, color: Colors.grey),
              const SizedBox(width: 4),
              Text('Delivery fee held in escrow', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _addToCart(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final buyerId = prefs.getString('auth_user_id') ?? '';
    if (buyerId.isEmpty) return;

    context.read<CartCubit>().addItem(
      buyerId,
      widget.product.id,
      variantLabel: _selectedVariant?.label,
      variantPrice: _selectedVariant?.price,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Added to cart'), duration: Duration(seconds: 1)),
      );
    }
  }

  Future<void> _contactVendor(BuildContext context) async {
    // Cross-state: view only — can't chat a vendor outside your state.
    if (!_isAvailableInState) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          'This vendor is in ${widget.product.vendorState}. You can only chat vendors in your own state.')),
      );
      return;
    }
    // KYC: must be verified to chat a vendor.
    if (!await requireKyc(context)) return;
    if (!context.mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final buyerId = prefs.getString('auth_user_id') ?? '';
    if (buyerId.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please log in as a buyer to chat')),
        );
      }
      return;
    }

    String vendorId = '';
    String storeName = 'Store';

    final cubitState = context.read<MarketplaceCubit>().state;
    final storeFromState = cubitState.stores[widget.product.storeId];
    if (storeFromState != null) {
      vendorId = storeFromState.vendorId;
      storeName = storeFromState.name;
    }

    if (vendorId.isEmpty) {
      final storeData = await SupabaseService.client.from('stores').select('id, name, vendor_id, description, logo_path, address, phone, created_at').eq('id', widget.product.storeId).maybeSingle();
      if (storeData != null) {
        final storeFromDb = Store.fromJson(storeData);
        vendorId = storeFromDb.vendorId;
        storeName = storeFromDb.name;
      }
    }

    if (vendorId.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vendor not found')),
        );
      }
      return;
    }

    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          orderId: 'product_${widget.product.id}',
          buyerId: buyerId,
          vendorId: vendorId,
          vendorName: storeName,
          buyerName: 'You',
          productInfo: {
            'id': widget.product.id,
            'name': widget.product.name,
            'price': _displayPrice,
            'storeId': widget.product.storeId,
            'storeName': storeName,
            'image': widget.product.imageList.isNotEmpty ? widget.product.imageList.first : null,
            'deliveryType': widget.product.deliveryType,
          },
        ),
      ),
    );
  }
}
