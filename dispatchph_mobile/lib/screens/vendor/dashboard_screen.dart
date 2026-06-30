import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../theme/app_theme.dart';
import '../auth/welcome_screen.dart';
import '../../bloc_exports.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/share_service.dart';
import '../../core/models/models.dart';
import '../../widgets/app_image.dart';
import '../delivery/vendor_locations_screen.dart';
import '../../widgets/loading_skeleton.dart';
import '../notifications/notification_bell_icon.dart';
import '../notifications/notification_screen.dart';
import '../chat/chat_list_screen.dart';
import 'add_product_screen.dart';
import 'edit_product_screen.dart';
import '../marketplace/vendor_store_screen.dart';
import 'orders_screen.dart';
import '../disputes/vendor_disputes_screen.dart';
import 'bank_account_screen.dart';
import '../policy/policy_screen.dart';

class VendorDashboard extends StatefulWidget {
  const VendorDashboard({super.key});

  @override
  State<VendorDashboard> createState() => _VendorDashboardState();
}

class _VendorDashboardState extends State<VendorDashboard> {
  Timer? _notifPoll;
  String _storeId = '';
  Store? _store;
  String _vendorName = 'Vendor';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _storeId = await AuthService.getStoreId();
    _vendorName = await AuthService.getUserName();
    if (_storeId.isNotEmpty) {
      _loadStore();
      context.read<MarketplaceCubit>().loadStoreProducts(_storeId);
      context.read<DisputeCubit>().loadDisputesForVendor(_storeId);
    }
    final userId = await AuthService.getUserId();
    context.read<OrderCubit>().loadVendorOrders(userId);
    context.read<NotificationCubit>().loadNotifications(userId);
    _notifPoll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) {
        context.read<NotificationCubit>().loadNotifications(userId);
      }
    });
  }

  Future<void> _loadStore() async {
    try {
      final data = await SupabaseService.client
          .from('stores')
          .select('id, name, vendor_id, description, logo_path, address, phone, created_at, handle, store_banner_url, is_verified')
          .eq('id', _storeId)
          .maybeSingle();
      if (data != null && mounted) {
        setState(() => _store = Store.fromJson(data));
      }
    } catch (e) {
      print('[VendorDashboard] _loadStore error: $e');
    }
  }

  @override
  void dispose() {
    _notifPoll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Press back again to exit')),
          );
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.lightGray,
        body: BlocBuilder<MarketplaceCubit, MarketplaceState>(
          builder: (context, state) {
            final storeProducts = state.storeProducts;
            final loading = state.isLoadingStoreProducts && storeProducts.isEmpty;
            return Column(
              children: [
                _buildHeader(context),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () async {
                      if (_storeId.isNotEmpty) {
                        context.read<MarketplaceCubit>().loadStoreProducts(_storeId);
                      }
                      _loadStore();
                      final userId = await AuthService.getUserId();
                      context.read<OrderCubit>().loadVendorOrders(userId);
                      context.read<NotificationCubit>().loadNotifications(userId);
                      if (_storeId.isNotEmpty) {
                        context.read<DisputeCubit>().loadDisputesForVendor(_storeId);
                      }
                    },
                    child: loading
                        ? _buildLoadingSkeleton()
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                            children: [
                              _buildStatsStrip(context, storeProducts),
                              const SizedBox(height: 16),
                              _buildPrimaryActions(context),
                              const SizedBox(height: 22),
                              _buildProductsSection(context, storeProducts),
                            ],
                          ),
                  ),
                ),
              ],
            );
          },
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AddProductScreen()),
          ),
          backgroundColor: AppColors.riderYellow,
          foregroundColor: AppColors.charcoal,
          elevation: 4,
          child: const Icon(Icons.add, size: 28),
        ),
      ),
    );
  }

  // Compact ₦ formatter for the stats strip (e.g. ₦310k, ₦1.2M).
  String _money(num v) {
    if (v >= 1000000) return '₦${(v / 1000000).toStringAsFixed(v % 1000000 == 0 ? 0 : 1)}M';
    if (v >= 1000) return '₦${(v / 1000).toStringAsFixed(v % 1000 == 0 ? 0 : 1)}k';
    return '₦${v.toStringAsFixed(0)}';
  }

  // Full-bleed green store header: top bar (menu/title/bell/chat) + store
  // identity (logo, name, verified, handle, view-store shortcut).
  Widget _buildHeader(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final handle = _store?.handle;
    final subtitle = (handle != null && handle.isNotEmpty)
        ? '@$handle'
        : 'Tap “View store” to preview your shop';
    return Container(
      padding: EdgeInsets.fromLTRB(16, topPad + 10, 16, 18),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primaryGreen, AppColors.darkGreen],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.menu_rounded, color: Colors.white, size: 26),
                onPressed: () => _showVendorMenu(context),
              ),
              const SizedBox(width: 10),
              const Text('My Store',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              NotificationBellIcon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const NotificationScreen()),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline, color: Colors.white),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ChatListScreen()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              CircleAvatar(
                radius: 27,
                backgroundColor: Colors.white.withAlpha(40),
                child: (_store?.logoPath != null && _store!.logoPath!.isNotEmpty)
                    ? ClipOval(
                        child: AppImage(source: _store!.logoPath, width: 54, height: 54, fit: BoxFit.cover))
                    : Text(
                        _vendorName.isNotEmpty ? _vendorName[0].toUpperCase() : 'S',
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _store?.name ?? _vendorName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (_store?.isVerified == true) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.verified, color: Colors.white, size: 17),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withAlpha(210), fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  if (_storeId.isNotEmpty) {
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => VendorStoreScreen(storeId: _storeId)));
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(46),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('View store →',
                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showVendorMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.mediumGray,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            _buildMenuItem(
              context,
              Icons.add_circle,
              'Add Product',
              () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AddProductScreen()),
                );
              },
            ),
            _buildMenuItem(
              context,
              Icons.store,
              'My Store',
              () {
                Navigator.pop(context);
                if (_storeId.isNotEmpty) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => VendorStoreScreen(storeId: _storeId)),
                  );
                }
              },
            ),
            _buildMenuItem(
              context,
              Icons.shopping_bag,
              'Orders',
              () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const VendorOrdersScreen()),
                );
              },
            ),
            _buildMenuItem(
              context,
              Icons.warning,
              'Disputes',
              () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const VendorDisputesScreen()),
                );
              },
            ),
            _buildMenuItem(
              context,
              Icons.location_on,
              'Pickup Locations',
              () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const VendorLocationsScreen()),
                );
              },
            ),
            _buildMenuItem(
              context,
              Icons.account_balance,
              'Bank Account',
              () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BankAccountScreen()),
                );
              },
            ),
            _buildMenuItem(
              context,
              Icons.description_outlined,
              'Terms & Policy',
              () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PolicyScreen()),
                );
              },
            ),
            const Divider(height: 24),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.errorRed.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.logout, color: AppColors.errorRed),
              ),
              title: const Text('Logout', style: TextStyle(color: AppColors.errorRed)),
              onTap: () async {
                final rootContext = Navigator.of(context, rootNavigator: true).context;
                Navigator.of(context, rootNavigator: true).pop();
                showDialog(
                  context: rootContext,
                  barrierDismissible: false,
                  builder: (_) => const Center(child: CircularProgressIndicator()),
                );
                try {
                  await AuthService.logout();
                } catch (_) {}
                Navigator.of(rootContext).pop();
                Navigator.of(rootContext).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const WelcomeScreen()),
                  (route) => false,
                );
              },
            ),
            const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuItem(BuildContext context, IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.primaryGreen.withAlpha(20),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: AppColors.primaryGreen),
      ),
      title: Text(label),
      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
      onTap: onTap,
    );
  }

  Widget _buildStatsStrip(BuildContext context, List<Product> products) {
    final ordersCount = context.watch<OrderCubit>().state.vendorOrders
        .where((o) => o.status == 'paid').length;
    final earnings = context.watch<OrderCubit>().state.vendorOrders
        .where((o) => o.status == 'confirmed' || o.status == 'auto_released')
        .fold<double>(0, (s, o) => s + o.total);
    final productsCount = products.length;

    Widget metric(String value, String label, Color color) => Expanded(
          child: Column(
            children: [
              Text(value,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 3),
              Text(label, style: const TextStyle(fontSize: 11, color: AppColors.mediumGray)),
            ],
          ),
        );
    Widget divider() => Container(width: 1, height: 32, color: AppColors.lightGray);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(12), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Row(
        children: [
          metric('$ordersCount', 'Open orders', AppColors.primaryGreen),
          divider(),
          metric(_money(earnings), 'Earnings', AppColors.charcoal),
          divider(),
          metric('$productsCount', 'Products', AppColors.primaryBlue),
        ],
      ),
    );
  }

  Widget _buildPrimaryActions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AddProductScreen()),
            ),
            icon: const Icon(Icons.add, size: 20),
            label: const Text('Add Product'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryGreen,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _shareStore,
            icon: const Icon(Icons.ios_share, size: 18),
            label: const Text('Share Store'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primaryGreen,
              side: const BorderSide(color: AppColors.primaryGreen, width: 1.5),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ],
    );
  }

  void _shareStore() {
    if (_storeId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your store is still loading — try again in a moment.')),
      );
      return;
    }
    final banner = _store?.storeBannerUrl;
    final logo = _store?.logoPath;
    ShareService.shareStore(
      handle: _store?.handle,
      storeId: _storeId,
      storeName: _store?.name ?? _vendorName,
      imageUrl: (banner != null && banner.isNotEmpty) ? banner : logo,
    );
  }

  Widget _buildProductsSection(BuildContext context, List<Product> products) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'My Products',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.charcoal),
            ),
            if (products.isNotEmpty)
              GestureDetector(
                onTap: () {
                  if (_storeId.isNotEmpty) {
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => VendorStoreScreen(storeId: _storeId)));
                  }
                },
                child: const Text('Manage all →',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primaryGreen)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (products.isEmpty)
          _buildEmptyProducts()
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: products.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.74,
            ),
            itemBuilder: (context, index) => _buildProductCard(context, products[index]),
          ),
      ],
    );
  }

  Widget _buildEmptyProducts() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primaryGreen.withAlpha(30)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.primaryGreen.withAlpha(10),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.inventory_2, color: AppColors.primaryGreen, size: 32),
          ),
          const SizedBox(height: 16),
          const Text(
            'No Products Yet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryGreen,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add your first product to start selling',
            style: TextStyle(color: Colors.grey[500]),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AddProductScreen()),
            ),
            icon: const Icon(Icons.add, size: 20),
            label: const Text('Add Product'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryGreen,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductCard(BuildContext context, Product product) {
    final isOutOfStock = product.stock == 0;
    final images = product.imageList;
    final imageUrl = images.isNotEmpty ? images.first : null;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => EditProductScreen(product: product)),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(15),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
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
                              child: Icon(Icons.inventory_2, color: AppColors.mediumGray, size: 32),
                            ),
                          ),
                  ),
                  if (isOutOfStock)
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
                        child: const Text(
                          'OUT OF STOCK',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          product.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                      ),
                      _PopupMenu(product: product),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '₦${product.price.toStringAsFixed(0)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.primaryGreen),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: isOutOfStock
                              ? AppColors.errorRed.withAlpha(20)
                              : AppColors.primaryGreen.withAlpha(20),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          isOutOfStock ? 'Out' : 'In stock',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: isOutOfStock ? AppColors.errorRed : AppColors.primaryGreen,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        LoadingSkeleton(height: 74, borderRadius: 16),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: LoadingSkeleton(height: 48, borderRadius: 14)),
            const SizedBox(width: 12),
            Expanded(child: LoadingSkeleton(height: 48, borderRadius: 14)),
          ],
        ),
        const SizedBox(height: 22),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: 4,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.74,
          ),
          itemBuilder: (_, __) => LoadingSkeleton(height: double.infinity, borderRadius: 14),
        ),
      ],
    );
  }
}

class _PopupMenu extends StatelessWidget {
  final Product product;
  const _PopupMenu({required this.product});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 16, color: AppColors.mediumGray),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onSelected: (value) {
        if (value == 'edit') {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => EditProductScreen(product: product)),
          );
        } else if (value == 'share') {
          final imgs = product.imageList;
          ShareService.shareProduct(
            productId: product.id,
            name: product.name,
            price: product.price,
            imageUrl: imgs.isNotEmpty ? imgs.first : null,
          );
        } else if (value == 'delete') {
          _confirmDelete(context, product);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              Icon(Icons.edit, size: 16, color: AppColors.primaryGreen),
              SizedBox(width: 8),
              Text('Edit'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'share',
          child: Row(
            children: [
              Icon(Icons.share, size: 16, color: AppColors.primaryGreen),
              SizedBox(width: 8),
              Text('Share'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete, size: 16, color: AppColors.errorRed),
              SizedBox(width: 8),
              Text('Delete', style: TextStyle(color: AppColors.errorRed)),
            ],
          ),
        ),
      ],
    );
  }

  void _confirmDelete(BuildContext context, Product product) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Product'),
        content: Text('Are you sure you want to delete "${product.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                // Delete via the cubit so the dashboard's store list refreshes
                // automatically (it re-fetches the active store).
                await context.read<MarketplaceCubit>().deleteProduct(product.id);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e')),
                  );
                }
              }
            },
            child: const Text('Delete', style: TextStyle(color: AppColors.errorRed)),
          ),
        ],
      ),
    );
  }
}
