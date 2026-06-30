import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/auth_service.dart';
import '../../widgets/online_indicator.dart';
import '../../widgets/app_image.dart';
import 'product_detail_screen.dart';
import '../auth/welcome_screen.dart';
import '../chat/chat_screen.dart';
import '../vendor/vendor_store_settings_screen.dart';
import '../kyc/kyc_screen.dart';

class VendorStoreScreen extends StatefulWidget {
  final String storeId;
  const VendorStoreScreen({super.key, required this.storeId});

  @override
  State<VendorStoreScreen> createState() => _VendorStoreScreenState();
}

class _VendorStoreScreenState extends State<VendorStoreScreen> {
  bool _vendorOnline = false;
  String? _vendorUniqueId;
  String? _currentUserId;
  String? _vendorName;
  int _completedOrders = 0;

  @override
  void initState() {
    super.initState();
    _currentUserId = SupabaseService.auth.currentUser?.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MarketplaceCubit>().loadProducts();
      context.read<ReviewCubit>().loadStoreReviews(widget.storeId);
      _checkOnline();
      _loadCompletedOrders();
    });
  }

  Future<void> _loadCompletedOrders() async {
    try {
      final data = await SupabaseService.client
          .from('orders')
          .select('id')
          .eq('store_id', widget.storeId)
          .inFilter('status', ['confirmed', 'auto_released']);
      if (mounted) setState(() => _completedOrders = (data as List).length);
    } catch (e) {
      print('[VendorStoreScreen] _loadCompletedOrders error: $e');
    }
  }

  Future<void> _checkOnline() async {
    final storeData = await SupabaseService.client.from('stores').select('id, name, vendor_id, description, logo_path, address, phone, created_at').eq('id', widget.storeId).maybeSingle();
    if (storeData != null) {
      final store = Store.fromJson(storeData);
      Map<String, dynamic>? vendorData;
      try {
        vendorData = await SupabaseService.client.from('public_profiles').select('id, name, last_active, unique_id').eq('id', store.vendorId).maybeSingle();
      } catch (_) {
        vendorData = await SupabaseService.client.from('public_profiles').select('id, name, last_active').eq('id', store.vendorId).maybeSingle();
      }
      final vendor = vendorData != null ? AppUser.fromJson(vendorData) : null;
      if (mounted) {
        setState(() {
          _vendorOnline = AuthService.isOnline(vendor);
          _vendorUniqueId = vendorData?['unique_id'] as String?;
          _vendorName = vendor?.name;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Store'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _shareStore,
          ),
        ],
      ),
      body: BlocBuilder<MarketplaceCubit, MarketplaceState>(
        builder: (context, state) {
          final store = state.stores[widget.storeId];
          final products = state.products.where((p) => p.storeId == widget.storeId).toList();
          return ListView(
            padding: EdgeInsets.zero,
            children: [
              if (store != null) ...[
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      height: 130,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.primaryGreen,
                        image: (store.storeBannerUrl != null && store.storeBannerUrl!.isNotEmpty)
                            ? DecorationImage(image: NetworkImage(store.storeBannerUrl!), fit: BoxFit.cover)
                            : null,
                      ),
                    ),
                    Positioned(
                      bottom: -32,
                      left: 16,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          color: Colors.white,
                        ),
                        child: ClipOval(
                          child: (store.logoPath != null && store.logoPath!.isNotEmpty)
                              ? AppImage(source: store.logoPath!, fit: BoxFit.cover)
                              : const Icon(Icons.store, size: 32, color: AppColors.primaryGreen),
                        ),
                      ),
                    ),
                    if (store.isVerified)
                      Positioned(
                        bottom: -28,
                        left: 64,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                          child: const Icon(Icons.verified, color: AppColors.primaryGreen, size: 18),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 40),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(store.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                          if (store.isVerified) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.verified, color: AppColors.primaryGreen, size: 16),
                          ],
                          const SizedBox(width: 8),
                          OnlineIndicator(isOnline: _vendorOnline),
                          const SizedBox(width: 4),
                          Text(
                            _vendorOnline ? 'Online' : 'Offline',
                            style: TextStyle(
                              fontSize: 12,
                              color: _vendorOnline ? Colors.green : AppColors.mediumGray,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      if (store.address != null && store.address!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.location_on, size: 14, color: AppColors.mediumGray),
                            const SizedBox(width: 4),
                            Text(store.address!, style: const TextStyle(color: AppColors.mediumGray, fontSize: 13)),
                          ],
                        ),
                      ],
                      if (store.description != null) ...[
                        const SizedBox(height: 8),
                        Text(store.description!, style: const TextStyle(color: AppColors.mediumGray)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                BlocBuilder<ReviewCubit, ReviewState>(
                  builder: (context, reviewState) {
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _statItem('⭐', reviewState.averageRating.toStringAsFixed(1), 'Rating'),
                          _statDivider(),
                          _statItem('📦', '$_completedOrders', 'Orders'),
                          _statDivider(),
                          _statItem('🕐', _responseTimeLabel(store.responseTime), 'Response'),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildContactSection(context, store),
                ),
                const SizedBox(height: 16),
              ],

              if (_isOwner(store) && _vendorUniqueId != null) ...[
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.primaryGreen.withAlpha(12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primaryGreen.withAlpha(40)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.primaryGreen.withAlpha(25),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.storefront, color: AppColors.primaryGreen, size: 20),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Your Store ID',
                              style: TextStyle(fontSize: 12, color: AppColors.mediumGray),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _vendorUniqueId!,
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.charcoal),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: _copyId,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.mediumGray.withAlpha(60)),
                          ),
                          child: const Icon(Icons.copy, size: 18, color: AppColors.charcoal),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _shareStore,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.primaryGreen,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.share, size: 18, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => VendorStoreSettingsScreen(store: store!)),
                      ),
                      icon: const Icon(Icons.edit, size: 18, color: AppColors.primaryGreen),
                      label: const Text('Edit Store Profile', style: TextStyle(color: AppColors.primaryGreen)),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.primaryGreen)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Reviews summary (clickable)
              BlocBuilder<ReviewCubit, ReviewState>(
                builder: (context, reviewState) {
                  if (reviewState.isLoading) return const SizedBox.shrink();
                  return GestureDetector(
                    onTap: reviewState.reviews.isNotEmpty
                        ? () => _showAllReviews(context, reviewState.reviews)
                        : null,
                    child: Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    _RatingStars(rating: reviewState.averageRating, size: 20),
                                    const SizedBox(width: 8),
                                    Text(
                                      reviewState.averageRating.toStringAsFixed(1),
                                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  reviewState.reviews.isEmpty
                                      ? 'No reviews yet'
                                      : '${reviewState.reviewCount} ${reviewState.reviewCount == 1 ? 'review' : 'reviews'}',
                                  style: const TextStyle(color: AppColors.mediumGray),
                                ),
                              ],
                            ),
                            const Spacer(),
                            if (reviewState.reviews.isNotEmpty)
                              const Icon(Icons.chevron_right, color: AppColors.mediumGray),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),

              const SizedBox(height: 16),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('Products from this Store (${products.length})',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: products.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.72,
                  ),
                  itemBuilder: (context, i) {
                    final p = products[i];
                    final imgs = p.imageList;
                    final imageUrl = imgs.isNotEmpty ? imgs.first : null;
                    final out = p.stock == 0;
                    return GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ProductDetailScreen(product: p)),
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withAlpha(15), blurRadius: 8, offset: const Offset(0, 3)),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ClipRRect(
                                    borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                                    child: imageUrl != null
                                        ? AppImage(source: imageUrl, fit: BoxFit.cover)
                                        : Container(
                                            color: AppColors.lightGray,
                                            child: const Center(
                                              child: Icon(Icons.image, color: AppColors.mediumGray, size: 32),
                                            ),
                                          ),
                                  ),
                                  if (out)
                                    Container(
                                      decoration: const BoxDecoration(
                                        color: Color(0x66000000),
                                        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
                                      ),
                                      alignment: Alignment.center,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: AppColors.errorRed,
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Text('OUT OF STOCK',
                                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10)),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(p.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                  const SizedBox(height: 4),
                                  Text('\u20A6${format.format(p.price)}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.primaryGreen)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  String _responseTimeLabel(String? responseTime) {
    switch (responseTime) {
      case 'usually_fast':
        return 'Fast';
      case 'within_hours':
        return 'Hours';
      case 'within_day':
        return '1 Day';
      default:
        return 'Fast';
    }
  }

  Widget _statItem(String emoji, String value, String label) {
    return Column(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 18)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.mediumGray)),
      ],
    );
  }

  Widget _statDivider() => Container(width: 1, height: 32, color: AppColors.mediumGray.withAlpha(60));

  Widget _buildContactSection(BuildContext context, Store store) {
    if (_isOwner(store)) return const SizedBox.shrink();
    final isLoggedIn = _currentUserId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Contact Vendor', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 10),
        if (!isLoggedIn)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: Column(
              children: [
                const Icon(Icons.lock, color: Colors.grey, size: 32),
                const SizedBox(height: 8),
                const Text('Login to view vendor contact details',
                    style: TextStyle(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Text('Create a free account to contact vendors',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const WelcomeScreen()),
                        ),
                        child: const Text('Login'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const WelcomeScreen()),
                        ),
                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryGreen),
                        child: const Text('Sign Up', style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          )
        else
          Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _openChatWithVendor(context, store),
                  icon: const Icon(Icons.chat, color: Colors.white),
                  label: const Text('Chat in App', style: TextStyle(color: Colors.white, fontSize: 15)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (store.showPhoneToBuyers && store.phone != null && store.phone!.isNotEmpty)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => launchUrl(Uri.parse('tel:${store.phone}')),
                        icon: const Icon(Icons.phone, color: AppColors.primaryGreen, size: 18),
                        label: Text(store.phone!, style: const TextStyle(color: AppColors.primaryGreen)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.primaryGreen),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => launchUrl(Uri.parse(
                          'https://wa.me/${(store.whatsappNumber ?? store.phone)!.replaceAll('+', '').replaceAll(' ', '')}',
                        )),
                        icon: const Icon(Icons.message, color: Color(0xFF25D366), size: 18),
                        label: const Text('WhatsApp', style: TextStyle(color: Color(0xFF25D366))),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF25D366)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: store.phone!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Number copied')),
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.primaryGreen),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                      ),
                      child: const Icon(Icons.copy, color: AppColors.primaryGreen, size: 18),
                    ),
                  ],
                ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber[300]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.amber[700], size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '⚠️ Transactions outside Kay\'s app are not covered by escrow protection.',
                        style: TextStyle(fontSize: 11, color: Colors.amber[900]),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  Future<void> _openChatWithVendor(BuildContext context, Store store) async {
    if (_currentUserId == null) return;
    final cubit = context.read<MarketplaceCubit>();
    final buyerState = cubit.state.buyerState;
    final storeProducts = cubit.state.products.where((p) => p.storeId == store.id);
    final vendorState = storeProducts.isNotEmpty ? storeProducts.first.vendorState : null;

    // Cross-state: view only — can't chat a vendor outside your state.
    if (buyerState != null && vendorState != null && vendorState != buyerState) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          'This vendor is in $vendorState. You can only chat vendors in your own state.')),
      );
      return;
    }
    // KYC: must be verified to chat a vendor.
    if (!await requireKyc(context)) return;
    if (!context.mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          orderId: 'product_${store.id}',
          buyerId: _currentUserId!,
          vendorId: store.vendorId,
          vendorName: _vendorName ?? store.name,
          buyerName: 'You',
        ),
      ),
    );
  }

  bool _isOwner(Store? store) {
    if (store == null || _currentUserId == null) return false;
    return store.vendorId == _currentUserId;
  }

  void _copyId() {
    if (_vendorUniqueId == null) return;
    Clipboard.setData(ClipboardData(text: _vendorUniqueId!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Store ID copied'), duration: Duration(seconds: 1)),
    );
  }

  void _shareStore() {
    final store = context.read<MarketplaceCubit>().state.stores[widget.storeId];
    final storeName = store?.name ?? 'Store';
    if (_isOwner(store) && _vendorUniqueId != null) {
      Share.share(
        'Shop at $storeName on Kay\'s Marketplace!\n\n'
        'Store ID: $_vendorUniqueId\n'
        'Open Kay\'s Marketplace and search "$_vendorUniqueId" to find this store.',
      );
    } else {
      Share.share('Check out $storeName on Kay\'s Marketplace!');
    }
  }

  void _showAllReviews(BuildContext context, List<Review> reviews) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _AllReviewsScreen(reviews: reviews),
      ),
    );
  }
}

class _RatingStars extends StatelessWidget {
  final double rating;
  final double size;
  const _RatingStars({required this.rating, this.size = 16});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final starVal = i + 1;
        final filled = rating >= starVal;
        final half = !filled && rating >= starVal - 0.5;
        return Icon(
          filled ? Icons.star : half ? Icons.star_half : Icons.star_border,
          size: size,
          color: AppColors.starYellow,
        );
      }),
    );
  }
}

class _ReviewTile extends StatelessWidget {
  final Review review;
  const _ReviewTile({required this.review});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: AppColors.primaryGreen.withAlpha(30),
                  child: Text(
                    (review.buyerName ?? 'B')[0].toUpperCase(),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.primaryGreen),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(review.buyerName ?? 'Buyer',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      _RatingStars(rating: review.rating.toDouble(), size: 14),
                    ],
                  ),
                ),
                Text(
                  _formatDate(review.createdAt),
                  style: const TextStyle(fontSize: 11, color: AppColors.mediumGray),
                ),
              ],
            ),
            if (review.comment != null && review.comment!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(review.comment!, style: const TextStyle(fontSize: 13, color: AppColors.charcoal)),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays > 7) return '${dt.day}/${dt.month}/${dt.year}';
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    return 'now';
  }
}

class _AllReviewsScreen extends StatelessWidget {
  final List<Review> reviews;
  const _AllReviewsScreen({required this.reviews});

  @override
  Widget build(BuildContext context) {
    double avg = 0;
    if (reviews.isNotEmpty) {
      avg = reviews.fold<double>(0, (sum, r) => sum + r.rating) / reviews.length;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Reviews')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _RatingStars(rating: avg, size: 22),
                const SizedBox(width: 8),
                Text(
                  avg.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Text(
                  '${reviews.length} ${reviews.length == 1 ? 'review' : 'reviews'}',
                  style: const TextStyle(color: AppColors.mediumGray, fontSize: 15),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: reviews.length,
              itemBuilder: (_, i) => _ReviewTile(review: reviews[i]),
            ),
          ),
        ],
      ),
    );
  }
}
