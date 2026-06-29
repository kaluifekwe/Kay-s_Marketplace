import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../theme/app_theme.dart';
import '../auth/welcome_screen.dart';
import '../../bloc_exports.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
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
          .select('id, name, vendor_id, description, logo_path, address, phone, created_at')
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
        appBar: _buildAppBar(context),
        body: BlocBuilder<MarketplaceCubit, MarketplaceState>(
          builder: (context, state) {
            if (state.isLoading) {
              return _buildLoadingSkeleton();
            }
            final storeProducts = state.products
                .where((p) => p.storeId == _storeId)
                .toList();
            return RefreshIndicator(
              onRefresh: () async {
                context.read<MarketplaceCubit>().loadProducts();
                _loadStore();
                final userId = await AuthService.getUserId();
                context.read<OrderCubit>().loadVendorOrders(userId);
                context.read<NotificationCubit>().loadNotifications(userId);
                if (_storeId.isNotEmpty) {
                  context.read<DisputeCubit>().loadDisputesForVendor(_storeId);
                }
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildGreetingCard(),
                  const SizedBox(height: 16),
                  _buildQuickStats(context, storeProducts),
                  const SizedBox(height: 16),
                  _buildQuickActions(context),
                  const SizedBox(height: 20),
                  _buildProductsSection(context, storeProducts),
                ],
              ),
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

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.primaryGreen,
      elevation: 0,
      title: const Text(
        'Vendor Dashboard',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 20,
        ),
      ),
      leading: IconButton(
        icon: const Icon(Icons.menu_rounded, color: Colors.white),
        onPressed: () => _showVendorMenu(context),
      ),
      actions: [
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
    );
  }

  void _showVendorMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
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

  Widget _buildGreetingCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primaryGreen, AppColors.darkGreen],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryGreen.withAlpha(60),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hello, $_vendorName',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Welcome back to your store',
                  style: TextStyle(
                    color: Colors.white.withAlpha(200),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          CircleAvatar(
            radius: 30,
            backgroundColor: Colors.white.withAlpha(30),
            child: _store?.logoPath != null
                ? ClipOval(
                    child: AppImage(
                      source: _store!.logoPath,
                      width: 60,
                      height: 60,
                      fit: BoxFit.cover,
                    ),
                  )
                : const Icon(Icons.store, color: Colors.white, size: 30),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickStats(BuildContext context, List<Product> products) {
    final disputesCount = context.watch<DisputeCubit>().state.vendorDisputes.length;
    final ordersCount = context.watch<OrderCubit>().state.vendorOrders
        .where((o) => o.status == 'paid').length;
    final productsCount = products.length;

    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            icon: Icons.shopping_bag,
            value: '$ordersCount',
            label: 'Orders',
            color: AppColors.primaryGreen,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            icon: Icons.warning_amber,
            value: '$disputesCount',
            label: 'Disputes',
            color: AppColors.warningOrange,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            icon: Icons.inventory_2,
            value: '$productsCount',
            label: 'Products',
            color: AppColors.primaryBlue,
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: color.withAlpha(30),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withAlpha(20),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.mediumGray,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quick Actions',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.charcoal,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildFilledActionButton(
                context,
                'Edit Store',
                Icons.storefront,
                AppColors.primaryGreen,
                () {
                  if (_storeId.isNotEmpty) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => VendorStoreScreen(storeId: _storeId)),
                    );
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildFilledActionButton(
                context,
                'Add Product',
                Icons.add_box,
                AppColors.riderYellow,
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AddProductScreen()),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildFilledActionButton(
                context,
                'Orders',
                Icons.shopping_bag,
                AppColors.primaryBlue,
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const VendorOrdersScreen()),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildFilledActionButton(
                context,
                'Disputes',
                Icons.warning_amber,
                AppColors.warningOrange,
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const VendorDisputesScreen()),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: _buildFilledActionButton(
            context,
            'Pickup Locations',
            Icons.location_on,
            AppColors.darkGreen,
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const VendorLocationsScreen()),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilledActionButton(
    BuildContext context,
    String label,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    final isYellow = color == AppColors.riderYellow;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(12),
      elevation: 2,
      shadowColor: color.withAlpha(60),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Icon(
                icon,
                color: isYellow ? AppColors.charcoal : Colors.white,
                size: 24,
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isYellow ? AppColors.charcoal : Colors.white,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
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
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.charcoal,
              ),
            ),
            Text(
              '${products.length} items',
              style: const TextStyle(color: AppColors.mediumGray),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (products.isEmpty)
          _buildEmptyProducts()
        else
          SizedBox(
            height: 200,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: products.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final product = products[index];
                return _buildProductCard(context, product);
              },
            ),
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
        width: 150,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
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
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                Container(
                  height: 120,
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: AppColors.lightGray,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                    child: imageUrl != null
                        ? AppImage(
                            source: imageUrl,
                            width: double.infinity,
                            height: 120,
                            fit: BoxFit.cover,
                          )
                        : const Center(
                            child: Icon(Icons.inventory_2, color: AppColors.mediumGray, size: 32),
                          ),
                  ),
                ),
                if (isOutOfStock)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(100),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      alignment: Alignment.center,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.errorRed,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'OUT OF STOCK',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(150),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '₦${product.price.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      product.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isOutOfStock
                                ? AppColors.errorRed.withAlpha(20)
                                : AppColors.primaryGreen.withAlpha(20),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            isOutOfStock ? 'Out of Stock' : 'In Stock',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: isOutOfStock ? AppColors.errorRed : AppColors.primaryGreen,
                            ),
                          ),
                        ),
                        const Spacer(),
                        _PopupMenu(product: product),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingSkeleton() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        LoadingSkeleton(height: 100, borderRadius: 16),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: LoadingSkeleton(height: 120, borderRadius: 12)),
            const SizedBox(width: 12),
            Expanded(child: LoadingSkeleton(height: 120, borderRadius: 12)),
            const SizedBox(width: 12),
            Expanded(child: LoadingSkeleton(height: 120, borderRadius: 12)),
          ],
        ),
        const SizedBox(height: 16),
        LoadingSkeleton(height: 80, borderRadius: 12),
        const SizedBox(height: 16),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: 4,
            itemBuilder: (_, __) => const Padding(
              padding: EdgeInsets.only(right: 12),
              child: ProductCardSkeleton(),
            ),
          ),
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
                await SupabaseService.client
                    .from('products')
                    .delete()
                    .eq('id', product.id);
                if (context.mounted) {
                  context.read<MarketplaceCubit>().loadProducts();
                }
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
