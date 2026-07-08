import 'dart:async';
import 'dart:convert';
import 'package:image_picker/image_picker.dart';
import '../../core/services/storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_image.dart';
import '../../widgets/loading_skeleton.dart';
import '../../widgets/delivery_badge.dart';
import '../../widgets/state_change_request_dialog.dart';
import '../../bloc_exports.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
import 'search_screen.dart';
import 'all_vendors_screen.dart';
import 'my_stores_screen.dart';
import 'product_detail_screen.dart';
import 'vendor_store_screen.dart';
import '../orders/cart_screen.dart';
import '../orders/buyer_orders_screen.dart';
import '../chat/chat_badge_icon.dart';
import '../chat/chat_list_screen.dart';
import '../notifications/notification_bell_icon.dart';
import '../notifications/notification_screen.dart';
import '../auth/welcome_screen.dart';
import 'my_rewards_screen.dart';
import 'buyer_bank_account_screen.dart';
import '../wallet/wallet_screen.dart';
import '../delivery/buyer_addresses_screen.dart';
import '../policy/policy_screen.dart';
import '../kyc/kyc_screen.dart';

class MarketplaceHome extends StatefulWidget {
  final int initialIndex;

  /// Set once, right after a new buyer registers and accepts the policy, to
  /// show the one-time welcome-credit dialog on top of the home screen.
  final bool showWelcomeCredit;

  const MarketplaceHome({
    super.key,
    this.initialIndex = 0,
    this.showWelcomeCredit = false,
  });

  @override
  State<MarketplaceHome> createState() => _MarketplaceHomeState();
}

class _MarketplaceHomeState extends State<MarketplaceHome> {
  late int _currentIndex = widget.initialIndex;
  Timer? _heartbeat;
  Timer? _notifPoll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MarketplaceCubit>().loadProducts();
      _loadCart();
      _loadChats();
      _loadNotifications();
      _loadBuyerState();
      AuthService.updateLastActive();
      _heartbeat = Timer.periodic(const Duration(minutes: 1), (_) {
        AuthService.updateLastActive();
      });
      _notifPoll = Timer.periodic(const Duration(seconds: 15), (_) {
        _loadNotifications();
        // Keep the message-icon unread badge live as new messages arrive.
        _loadChats();
      });
      if (widget.showWelcomeCredit) {
        _showWelcomeCreditDialog();
      } else {
        // Nudge unverified buyers to complete KYC (browsing is free; buying needs it).
        promptKycReminder(context);
      }
    });
  }

  void _showWelcomeCreditDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.celebration, color: AppColors.primaryGreen, size: 64),
        title: const Text("Welcome to Kays Market!"),
        content: const Text(
          "Congratulations! 🎉\nYou've received ₦200 welcome credit to use on your first purchase.",
          textAlign: TextAlign.center,
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Start Shopping'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _notifPoll?.cancel();
    super.dispose();
  }

  Future<void> _loadCart() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('auth_user_id') ?? '';
    if (userId.isNotEmpty && mounted) {
      context.read<CartCubit>().loadCart(userId);
    }
  }

  Future<void> _loadChats() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('auth_user_id') ?? '';
    if (userId.isNotEmpty && mounted) {
      context.read<ChatCubit>().loadChatsForBuyer(userId);
    }
  }

  Future<void> _loadNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('auth_user_id') ?? '';
    if (userId.isNotEmpty && mounted) {
      context.read<NotificationCubit>().loadNotifications(userId);
    }
  }

  Future<void> _loadBuyerState() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('auth_user_id') ?? '';
    if (userId.isNotEmpty && mounted) {
      context.read<MarketplaceCubit>().loadBuyerState(userId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      const _MarketplaceFeed(),
      const CartScreen(),
      const BuyerOrdersScreen(),
      const ProfileTab(),
    ];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_currentIndex != 0) {
          setState(() => _currentIndex = 0);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Press back again to exit'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      },
      child: Scaffold(
        body: screens[_currentIndex],
        bottomNavigationBar: _CustomBottomNav(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
        ),
      ),
    );
  }
}

class _CustomBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _CustomBottomNav({required this.currentIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(15),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              _NavItem(
                icon: Icons.home_rounded,
                label: 'Home',
                isSelected: currentIndex == 0,
                onTap: () => onTap(0),
              ),
              BlocBuilder<CartCubit, CartState>(
                builder: (context, cartState) {
                  return _NavItem(
                    icon: Icons.shopping_cart_rounded,
                    label: 'Cart',
                    isSelected: currentIndex == 1,
                    onTap: () => onTap(1),
                    badgeCount: cartState.itemCount,
                  );
                },
              ),
              _NavItem(
                icon: Icons.receipt_long_rounded,
                label: 'Orders',
                isSelected: currentIndex == 2,
                onTap: () => onTap(2),
              ),
              _NavItem(
                icon: Icons.person_rounded,
                label: 'Profile',
                isSelected: currentIndex == 3,
                onTap: () => onTap(3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final int badgeCount;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: isSelected ? AppColors.primaryGreen : AppColors.mediumGray,
                ),
                if (badgeCount > 0)
                  Positioned(
                    top: -6,
                    right: -10,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: AppColors.errorRed,
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                      child: Text(
                        badgeCount > 99 ? '99+' : '$badgeCount',
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected ? AppColors.primaryGreen : AppColors.mediumGray,
              ),
            ),
            const SizedBox(height: 2),
            if (isSelected)
              Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  color: AppColors.primaryGreen,
                  shape: BoxShape.circle,
                ),
              )
            else
              const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

class _MarketplaceFeed extends StatelessWidget {
  const _MarketplaceFeed();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        backgroundColor: AppColors.primaryGreen,
        elevation: 0,
        leading: const SizedBox.shrink(),
        title: const Text(
          "Kays Market",
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.storefront_outlined, color: Colors.white),
            tooltip: 'My Stores',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MyStoresScreen()),
            ),
          ),
          NotificationBellIcon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationScreen()),
            ),
          ),
          ChatBadgeIcon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ChatListScreen()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: AppColors.primaryGreen,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SearchScreen()),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(15),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search_rounded, color: AppColors.primaryGreen, size: 22),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Search products...',
                        style: TextStyle(color: AppColors.mediumGray, fontSize: 14),
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 24,
                      color: AppColors.mediumGray.withAlpha(60),
                    ),
                    const SizedBox(width: 10),
                    const Icon(Icons.tune_rounded, color: AppColors.mediumGray, size: 20),
                  ],
                ),
              ),
            ),
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: const [
                  _CategoryChip('All', null),
                  _CategoryChip('Food', 'Food'),
                  _CategoryChip('Fashion', 'Fashion'),
                  _CategoryChip('Electronics', 'Electronics'),
                  _CategoryChip('Health', 'Health'),
                  _CategoryChip('Home', 'Home'),
                  _CategoryChip('Other', 'Other'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          BlocBuilder<MarketplaceCubit, MarketplaceState>(
            buildWhen: (prev, curr) => prev.buyerState != curr.buyerState,
            builder: (context, state) {
              if (state.buyerState == null) return const SizedBox.shrink();
              return InkWell(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AllVendorsScreen()),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: AppColors.primaryGreen.withAlpha(20),
                  child: Row(
                    children: [
                      const Icon(Icons.location_on, color: AppColors.primaryGreen, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        '${state.buyerState} Marketplace',
                        style: const TextStyle(
                          color: AppColors.primaryGreen,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const Spacer(),
                      const Text(
                        'View all vendors',
                        style: TextStyle(color: AppColors.primaryGreen, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      const Icon(Icons.chevron_right, color: AppColors.primaryGreen, size: 18),
                    ],
                  ),
                ),
              );
            },
          ),
          Expanded(
            child: BlocBuilder<MarketplaceCubit, MarketplaceState>(
              builder: (context, state) {
                if (state.isLoading) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        childAspectRatio: 0.68,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: 6,
                      itemBuilder: (_, _) => const _ShimmerProductCard(),
                    ),
                  );
                }
                if (state.products.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            color: AppColors.primaryGreen.withAlpha(15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.storefront_rounded,
                            size: 56,
                            color: AppColors.primaryGreen,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'No products found',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: AppColors.charcoal,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Check back later for new items',
                          style: TextStyle(fontSize: 13, color: AppColors.mediumGray),
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: () => context.read<MarketplaceCubit>().loadProducts(),
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Retry'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryGreen,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return RefreshIndicator(
                  color: AppColors.primaryGreen,
                  onRefresh: () {
                    final cubit = context.read<MarketplaceCubit>();
                    // Preserve the active category filter on refresh instead of
                    // snapping back to "All".
                    return state.selectedCategory != null
                        ? cubit.loadProductsByCategory(state.selectedCategory!)
                        : cubit.loadProducts();
                  },
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (scrollInfo) {
                      if (scrollInfo.metrics.pixels > scrollInfo.metrics.maxScrollExtent - 200) {
                        final cubit = context.read<MarketplaceCubit>();
                        if (state.selectedCategory != null) {
                          cubit.loadMoreByCategory();
                        } else if (state.searchQuery != null && state.searchQuery!.isNotEmpty) {
                          cubit.loadMoreSearchResults();
                        } else {
                          cubit.loadMoreProducts();
                        }
                      }
                      return false;
                    },
                    child: GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        childAspectRatio: 0.68,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: state.products.length + (state.hasMore ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i == state.products.length) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        }
                        return _ProductCard(
                          product: state.products[i],
                          storeName: state.stores[state.products[i].storeId]?.name ?? 'Store',
                          buyerState: state.buyerState,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ProductDetailScreen(product: state.products[i]),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final String? category;
  const _CategoryChip(this.label, this.category);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: BlocBuilder<MarketplaceCubit, MarketplaceState>(
        builder: (context, state) {
          final selected = state.selectedCategory == category;
          return GestureDetector(
            onTap: () {
              if (category == null) {
                context.read<MarketplaceCubit>().loadProducts();
              } else {
                context.read<MarketplaceCubit>().loadProductsByCategory(category!);
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? AppColors.primaryGreen : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? AppColors.primaryGreen : AppColors.mediumGray.withAlpha(80),
                  width: 1,
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: AppColors.primaryGreen.withAlpha(40),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) ...[
                    const Icon(Icons.check_rounded, size: 16, color: Colors.white),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? Colors.white : AppColors.charcoal,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  final dynamic product;
  final String storeName;
  final String? buyerState;
  final VoidCallback onTap;

  const _ProductCard({
    required this.product,
    required this.storeName,
    this.buyerState,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0');
    final images = jsonDecode(product.images ?? '[]') as List;
    final hasImages = images.isNotEmpty;
    final stock = product.stock ?? 0;
    final isLowStock = stock > 0 && stock <= 5;
    final isOutOfStock = stock == 0;
    final vendorState = product.vendorState as String?;
    final isAvailableInState = buyerState == null || vendorState == null || vendorState == buyerState;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(12),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: Stack(
                children: [
                  Container(
                    width: double.infinity,
                    decoration: const BoxDecoration(
                      color: AppColors.lightGray,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                    ),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                      child: hasImages
                          ? AppImage(
                              source: images.first.toString(),
                              fit: BoxFit.cover,
                            )
                          : const Center(
                              child: Icon(Icons.image_outlined, size: 40, color: AppColors.mediumGray),
                            ),
                    ),
                  ),
                  if (!isAvailableInState)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(160),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.lock, size: 11, color: Colors.white),
                            SizedBox(width: 3),
                            Text(
                              'Not in your state',
                              style: TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w600),
                            ),
                          ],
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
                        child: const Center(
                          child: Text(
                            'OUT OF STOCK',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.charcoal,
                        height: 1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => VendorStoreScreen(storeId: product.storeId)),
                      ),
                      child: Text(
                        storeName,
                        style: const TextStyle(fontSize: 11, color: AppColors.mediumGray),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 2),
                    deliveryBadge(product.deliveryType as String?),
                    if (vendorState != null) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            Icons.location_on,
                            size: 11,
                            color: isAvailableInState ? AppColors.primaryGreen : AppColors.mediumGray,
                          ),
                          const SizedBox(width: 2),
                          Expanded(
                            child: Text(
                              vendorState,
                              style: TextStyle(
                                fontSize: 10,
                                color: isAvailableInState ? AppColors.primaryGreen : AppColors.mediumGray,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isAvailableInState)
                            const Icon(Icons.check_circle, size: 11, color: AppColors.primaryGreen),
                        ],
                      ),
                    ],
                    const Spacer(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            '\u20A6${format.format(product.price)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: AppColors.primaryGreen,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: isOutOfStock
                                ? AppColors.errorRed
                                : isLowStock
                                    ? AppColors.riderYellow
                                    : AppColors.primaryGreen,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            isOutOfStock
                                ? 'Out'
                                : isLowStock
                                    ? 'Low'
                                    : 'In Stock',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: isLowStock ? AppColors.charcoal : Colors.white,
                            ),
                          ),
                        ),
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
}

class _ShimmerProductCard extends StatelessWidget {
  const _ShimmerProductCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: LoadingSkeleton(
              width: double.infinity,
              height: double.infinity,
              borderRadius: 0,
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LoadingSkeleton(width: double.infinity, height: 12, borderRadius: 6),
                  const SizedBox(height: 6),
                  LoadingSkeleton(width: 80, height: 10, borderRadius: 5),
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      LoadingSkeleton(width: 60, height: 14, borderRadius: 7),
                      LoadingSkeleton(width: 40, height: 16, borderRadius: 8),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key});

  Future<Map<String, dynamic>> _loadProfileData() async {
    final name = await AuthService.getUserName();
    final userId = await AuthService.getUserId();
    String? state;
    String? avatarUrl;
    if (userId != null) {
      try {
        final data = await SupabaseService.client
            .from('users')
            .select('state, avatar_url')
            .eq('id', userId)
            .maybeSingle();
        state = data?['state'] as String?;
        avatarUrl = data?['avatar_url'] as String?;
      } catch (e) {
        print('[ProfileTab] loadState error: $e');
      }
    }
    return {'name': name, 'state': state, 'userId': userId, 'avatarUrl': avatarUrl};
  }

  void _showStateInfoDialog(BuildContext context, String? state) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.location_on, color: AppColors.primaryGreen, size: 40),
        title: const Text('Your State'),
        content: const Text(
          'You can only complete a purchase from vendors located in your own state. '
          'This is locked to keep delivery fast and reliable.',
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Got it'),
          ),
          if (state != null)
            TextButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                final userId = await AuthService.getUserId();
                if (userId != null && context.mounted) {
                  await showStateChangeRequestDialog(context, userId: userId, currentState: state);
                }
              },
              child: const Text('Request Change', style: TextStyle(color: AppColors.primaryGreen)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: FutureBuilder(
        future: _loadProfileData(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final name = snapshot.data!['name'] as String;
          final state = snapshot.data!['state'] as String?;
          final userId = snapshot.data!['userId'] as String?;
          final avatarUrl = snapshot.data!['avatarUrl'] as String?;
          Widget tile(IconData icon, String label, VoidCallback onTap, {bool danger = false}) {
            final color = danger ? AppColors.errorRed : AppColors.primaryGreen;
            return ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: color.withAlpha(20), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: color, size: 20),
              ),
              title: Text(label,
                  style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                      color: danger ? AppColors.errorRed : AppColors.charcoal)),
              trailing: danger ? null : const Icon(Icons.chevron_right, size: 18, color: AppColors.mediumGray),
              onTap: onTap,
            );
          }

          Widget card(List<Widget> children) => Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.mediumGray.withAlpha(40)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(children: children),
              );
          const divider = Divider(height: 1, indent: 60, color: Color(0xFFEFEFEF));

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 28),
            child: Column(
              children: [
                _BuyerAvatar(userId: userId, initialUrl: avatarUrl),
                const SizedBox(height: 14),
                Text(name, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 4),
                const Text('Buyer', style: TextStyle(color: AppColors.mediumGray)),
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: () => _showStateInfoDialog(context, state),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.primaryGreen.withAlpha(20),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.location_on, size: 16, color: AppColors.primaryGreen),
                        const SizedBox(width: 6),
                        Text(
                          state ?? 'State not set',
                          style: const TextStyle(
                            color: AppColors.primaryGreen,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.info_outline, size: 14, color: AppColors.primaryGreen.withAlpha(150)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                card([
                  tile(Icons.account_balance_wallet_outlined, 'Wallet',
                      () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WalletScreen()))),
                  divider,
                  tile(Icons.card_giftcard, 'My Rewards & Credit',
                      () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyRewardsScreen()))),
                  divider,
                  tile(Icons.location_on_outlined, 'My Delivery Addresses',
                      () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BuyerAddressesScreen()))),
                  divider,
                  tile(Icons.account_balance, 'Bank Account',
                      () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BuyerBankAccountScreen()))),
                  divider,
                  tile(Icons.storefront_outlined, 'My Stores',
                      () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyStoresScreen()))),
                  divider,
                  tile(Icons.verified_user_outlined, 'Verify Identity (KYC)',
                      () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KycScreen()))),
                  divider,
                  tile(Icons.description_outlined, 'Terms & Policy',
                      () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PolicyScreen()))),
                ]),
                const SizedBox(height: 14),
                card([
                  tile(Icons.logout, 'Logout', () async {
                    await AuthService.logout();
                    if (!context.mounted) return;
                    Navigator.pushAndRemoveUntil(
                      context,
                      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
                      (route) => false,
                    );
                  }, danger: true),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Tappable buyer avatar with pick + upload to the user's own storage folder,
/// saved to users.avatar_url. Encapsulates upload state so ProfileTab can stay
/// a simple FutureBuilder.
class _BuyerAvatar extends StatefulWidget {
  final String? userId;
  final String? initialUrl;
  const _BuyerAvatar({required this.userId, required this.initialUrl});

  @override
  State<_BuyerAvatar> createState() => _BuyerAvatarState();
}

class _BuyerAvatarState extends State<_BuyerAvatar> {
  final _picker = ImagePicker();
  String? _url;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _url = widget.initialUrl;
  }

  void _onTap() {
    if (widget.userId == null || _uploading) return;
    final hasPhoto = _url != null && _url!.isNotEmpty;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            if (hasPhoto)
              ListTile(
                leading: const Icon(Icons.visibility, color: AppColors.primaryGreen),
                title: const Text('View photo'),
                onTap: () {
                  Navigator.pop(context);
                  _view();
                },
              ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: AppColors.primaryGreen),
              title: Text(hasPhoto ? 'Change photo' : 'Add photo'),
              onTap: () {
                Navigator.pop(context);
                _pick();
              },
            ),
            if (hasPhoto)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: AppColors.errorRed),
                title: const Text('Remove photo', style: TextStyle(color: AppColors.errorRed)),
                onTap: () {
                  Navigator.pop(context);
                  _remove();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _view() {
    if (_url == null || _url!.isEmpty) return;
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            InteractiveViewer(child: AppImage(source: _url, fit: BoxFit.contain)),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pick() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
      maxWidth: 800,
      maxHeight: 800,
    );
    if (picked == null) return;
    setState(() => _uploading = true);
    final compressed = await StorageService.compressImage(picked);
    final url = await StorageService.uploadProductImage((compressed ?? picked).path, widget.userId!);
    if (url != null) {
      try {
        await SupabaseService.client.from('users').update({'avatar_url': url}).eq('id', widget.userId!);
        if (mounted) setState(() => _url = url);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save photo')));
        }
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upload failed, please try again')));
    }
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _remove() async {
    setState(() => _uploading = true);
    try {
      await SupabaseService.client.from('users').update({'avatar_url': null}).eq('id', widget.userId!);
      if (mounted) setState(() => _url = null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not remove photo')));
      }
    }
    if (mounted) setState(() => _uploading = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _uploading ? null : _onTap,
      child: Stack(
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryGreen),
            clipBehavior: Clip.antiAlias,
            child: _uploading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : (_url != null && _url!.isNotEmpty)
                    ? AppImage(source: _url, fit: BoxFit.cover)
                    : const Icon(Icons.person, size: 44, color: Colors.white),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primaryGreen),
              ),
              child: const Icon(Icons.camera_alt, size: 14, color: AppColors.primaryGreen),
            ),
          ),
        ],
      ),
    );
  }
}
