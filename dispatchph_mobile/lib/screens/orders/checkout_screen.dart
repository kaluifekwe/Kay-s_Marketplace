import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/models/delivery_models.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/credit_service.dart';
import '../../core/services/wallet_service.dart';
import '../../core/services/delivery_service.dart';
import '../delivery/buyer_addresses_screen.dart';
import '../kyc/kyc_screen.dart';
import '../wallet/add_money_screen.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  Map<String, String> _storeNames = {};
  Map<String, String> _storeVendorIds = {};
  Map<String, String> _storeDeliveryType = {};
  Map<String, double> _storeDeliveryFee = {};
  Map<String, double> _storeDeliveryContribution = {};
  Map<String, bool> _storeDeliveryAgreed = {};
  // Courier (Shipbubble) delivery state. Courier is the default delivery path;
  // when no courier covers a store's route we keep the free/negotiate fallback
  // computed in _loadData. Keyed by storeId to match the cart grouping.
  final Map<String, DeliveryQuote> _storeQuotes = {};
  final Map<String, CourierOption?> _storeCourier = {};
  final Map<String, bool> _storeQuoteLoading = {};
  BuyerAddress? _selectedAddress;
  bool _loaded = false;
  bool _useCredit = false;
  double _creditBalance = 0;
  String _buyerId = '';

  bool get _hasCourierDelivery => _storeCourier.values.any((c) => c != null);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _loadData();
    }
  }

  Future<void> _loadData() async {
    final cartState = context.read<CartCubit>().state;
    final storeIds = cartState.items
        .map((i) => cartState.productMap[i.productId]?.storeId)
        .whereType<String>()
        .toSet();

    final prefs = await SharedPreferences.getInstance();
    final buyerId = prefs.getString('auth_user_id') ?? '';

    final names = <String, String>{};
    final vendorIds = <String, String>{};
    final deliveryTypes = <String, String>{};
    final deliveryFees = <String, double>{};
    final deliveryContributions = <String, double>{};
    final deliveryAgreed = <String, bool>{};

    for (final storeId in storeIds) {
      try {
        final data = await SupabaseService.client
            .from('stores')
            .select('id, name, vendor_id')
            .eq('id', storeId)
            .maybeSingle();
        if (data == null) continue;
        names[storeId] = data['name'] as String;
        final vendorId = data['vendor_id'] as String;
        vendorIds[storeId] = vendorId;

        // A vendor's delivery policy is per-product, but for checkout purposes
        // we use the first item's policy from that store (vendors generally
        // apply one consistent policy across their catalog).
        final firstItem = cartState.items.firstWhere(
          (i) => cartState.productMap[i.productId]?.storeId == storeId,
        );
        final deliveryType = cartState.productMap[firstItem.productId]?.deliveryType ?? 'negotiate';
        deliveryTypes[storeId] = deliveryType;

        if (deliveryType == 'free') {
          deliveryFees[storeId] = 0;
          deliveryContributions[storeId] = 0;
          deliveryAgreed[storeId] = true;
          continue;
        }

        if (buyerId.isEmpty) {
          deliveryAgreed[storeId] = false;
          continue;
        }

        // Look for the most recently accepted delivery fee/split request in
        // any chat between this buyer and vendor.
        final chats = await SupabaseService.client
            .from('chats')
            .select('id')
            .eq('buyer_id', buyerId)
            .eq('vendor_id', vendorId);
        final chatIds = (chats as List).map((c) => c['id'] as String).toList();
        if (chatIds.isEmpty) {
          deliveryAgreed[storeId] = false;
          continue;
        }

        final accepted = await SupabaseService.client
            .from('messages')
            .select('buyer_fee_amount, vendor_contribution, created_at')
            .inFilter('chat_id', chatIds)
            .eq('delivery_fee_status', 'accepted')
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();

        if (accepted != null) {
          deliveryFees[storeId] = (accepted['buyer_fee_amount'] as num?)?.toDouble() ?? 0;
          deliveryContributions[storeId] = (accepted['vendor_contribution'] as num?)?.toDouble() ?? 0;
          deliveryAgreed[storeId] = true;
        } else {
          deliveryAgreed[storeId] = false;
        }
      } catch (e) {
        print('[Checkout] delivery info lookup error for $storeId: $e');
        deliveryAgreed[storeId] = false;
      }
    }

    double credit = 0;
    if (buyerId.isNotEmpty) {
      credit = await CreditService.getBalance(buyerId);
    }

    if (mounted) setState(() {
      _storeNames = names;
      _storeVendorIds = vendorIds;
      _storeDeliveryType = deliveryTypes;
      _storeDeliveryFee = deliveryFees;
      _storeDeliveryContribution = deliveryContributions;
      _storeDeliveryAgreed = deliveryAgreed;
      _creditBalance = credit;
      _buyerId = buyerId;
    });

    // Default to the buyer's saved address and fetch live courier rates.
    if (buyerId.isNotEmpty) {
      try {
        final defaultAddr = await DeliveryService.getDefaultBuyerAddress(buyerId);
        if (defaultAddr != null) {
          if (mounted) setState(() => _selectedAddress = defaultAddr);
          await _loadQuotes();
        }
      } catch (e) {
        debugPrint('[Checkout] address/quote load error: $e');
      }
    }
  }

  /// Fetch Shipbubble courier rates for every store using the selected delivery
  /// address. When a store has couriers, courier becomes its delivery method
  /// (cheapest pre-selected); otherwise the free/negotiate fallback stands.
  Future<void> _loadQuotes() async {
    final addr = _selectedAddress;
    if (addr == null || _buyerId.isEmpty) return;

    final cartState = context.read<CartCubit>().state;
    final storeIds = cartState.items
        .map((i) => cartState.productMap[i.productId]?.storeId)
        .whereType<String>()
        .toSet();

    for (final storeId in storeIds) {
      final vendorId = _storeVendorIds[storeId];
      if (vendorId == null) continue;
      // A vendor offering free delivery handles it themselves — no courier.
      if (_storeDeliveryType[storeId] == 'free') continue;

      // Items for this store, in the shape get-delivery-quotes expects.
      final items = cartState.items
          .where((i) => cartState.productMap[i.productId]?.storeId == storeId)
          .map((i) {
        final p = cartState.productMap[i.productId];
        return {
          'name': p?.name ?? 'Item',
          'weight': 0.5, // no per-product weight yet; matches server default
          'quantity': i.quantity,
          'amount': i.variantPrice ?? p?.price ?? 0,
        };
      }).toList();

      if (mounted) setState(() => _storeQuoteLoading[storeId] = true);
      try {
        final quote = await DeliveryService.getDeliveryQuotes(
          vendorId: vendorId,
          buyerId: _buyerId,
          deliveryAddress: addr.address,
          deliveryLandmark: addr.landmark,
          deliveryCity: addr.city,
          deliveryState: addr.state,
          deliveryLatitude: addr.latitude,
          deliveryLongitude: addr.longitude,
          items: items,
        );
        if (!mounted) return;
        setState(() {
          _storeQuoteLoading[storeId] = false;
          if (quote.hasCouriers) {
            final cheapest = quote.couriers.first;
            _storeQuotes[storeId] = quote;
            _storeCourier[storeId] = cheapest;
            _storeDeliveryType[storeId] = 'courier';
            _storeDeliveryFee[storeId] = cheapest.fee;
            _storeDeliveryContribution[storeId] = 0;
            _storeDeliveryAgreed[storeId] = true;
          }
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _storeQuoteLoading[storeId] = false);
        debugPrint('[Checkout] quote error for $storeId: $e');
      }
    }
  }

  Future<void> _changeAddress() async {
    final picked = await Navigator.push<BuyerAddress>(
      context,
      MaterialPageRoute(builder: (_) => BuyerAddressesScreen(buyerId: _buyerId, selectMode: true)),
    );
    if (picked == null) return;
    // New address invalidates every existing courier quote.
    setState(() {
      _selectedAddress = picked;
      _storeQuotes.clear();
      _storeCourier.clear();
      for (final storeId in _storeVendorIds.keys) {
        if (_storeDeliveryType[storeId] == 'courier') {
          _storeDeliveryType[storeId] = 'negotiate';
          _storeDeliveryAgreed[storeId] = false;
        }
      }
    });
    await _loadQuotes();
  }

  void _selectCourier(String storeId, CourierOption courier) {
    setState(() {
      _storeCourier[storeId] = courier;
      _storeDeliveryFee[storeId] = courier.fee;
    });
  }

  /// storeId -> { quote_id, courier_name } for every store the buyer chose a
  /// courier for. Threaded to create-payment, which re-verifies the fee from
  /// the stored quote before charging.
  Map<String, Map<String, String>> _buildCourierSelections() {
    final result = <String, Map<String, String>>{};
    _storeCourier.forEach((storeId, courier) {
      final quote = _storeQuotes[storeId];
      if (courier != null && quote?.quoteId != null) {
        result[storeId] = {
          'quote_id': quote!.quoteId!,
          'courier_name': courier.name,
          if (courier.optionRef != null) 'option_ref': courier.optionRef!,
        };
      }
    });
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0');
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: BlocBuilder<CartCubit, CartState>(
        builder: (context, state) {
          if (state.items.isEmpty) {
            return const Center(child: Text('Cart is empty'));
          }

          final Map<String, List<CartItem>> storeGroups = {};
          for (final item in state.items) {
            final product = state.productMap[item.productId];
            if (product == null) continue;
            storeGroups.putIfAbsent(product.storeId, () => []).add(item);
          }

          final totalDeliveryFee = storeGroups.keys.fold<double>(0, (sum, id) => sum + (_storeDeliveryFee[id] ?? 0));
          final totalVendorContribution =
              storeGroups.keys.fold<double>(0, (sum, id) => sum + (_storeDeliveryContribution[id] ?? 0));
          final totalWithDelivery = state.total + totalDeliveryFee;
          final deliveryUnagreed = storeGroups.keys.any((id) => _storeDeliveryAgreed[id] != true);
          final unagreedStoreNames = storeGroups.keys
              .where((id) => _storeDeliveryAgreed[id] != true)
              .map((id) => _storeNames[id] ?? 'this vendor')
              .toList();

          // Partial credit + card combination isn't supported yet — credit
          // can only be used when it fully covers the order total (incl. delivery).
          final canUseCreditFully = _creditBalance >= totalWithDelivery;
          final creditToUse = (_useCredit && canUseCreditFully) ? totalWithDelivery : 0.0;
          final amountToPay = totalWithDelivery - creditToUse;
          // Courier orders must pay via Paystack so the webhook can auto-book
          // the courier — credit checkout bypasses that path.
          final creditCoversFull = _useCredit && canUseCreditFully && !_hasCourierDelivery;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _deliveryAddressSection(),
              const SizedBox(height: 16),
              const Text('Order Summary', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              ...storeGroups.entries.map((entry) {
                final storeId = entry.key;
                final storeItems = entry.value;
                final storeName = _storeNames[storeId] ?? 'Store';

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.store, size: 16, color: AppColors.primaryGreen),
                            const SizedBox(width: 6),
                            Text(storeName,
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.primaryGreen)),
                          ],
                        ),
                        const Divider(height: 16),
                        ...storeItems.map((item) {
                          final p = state.productMap[item.productId];
                          if (p == null) return const SizedBox.shrink();
                          final unitPrice = item.variantPrice ?? p.price;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Container(
                                  width: 40, height: 40,
                                  decoration: BoxDecoration(
                                    color: AppColors.lightGray,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(Icons.image, color: AppColors.mediumGray, size: 20),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(p.name, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
                                      if (item.variantLabel != null)
                                        Text(item.variantLabel!,
                                            style: TextStyle(color: AppColors.primaryGreen, fontSize: 12)),
                                      Text('Qty: ${item.quantity} \u2022 \u20A6${format.format(unitPrice)}',
                                          style: const TextStyle(fontSize: 12, color: AppColors.mediumGray)),
                                    ],
                                  ),
                                ),
                                Text('\u20A6${format.format(unitPrice * item.quantity)}',
                                    style: const TextStyle(fontWeight: FontWeight.bold)),
                              ],
                            ),
                          );
                        }),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text(
                                'Subtotal: \u20A6${format.format(storeItems.fold<double>(0, (sum, item) {
                                  final p = state.productMap[item.productId];
                                  return sum + (p != null ? (item.variantPrice ?? p.price) * item.quantity : 0);
                                }))}',
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        _courierSelector(storeId),
                      ],
                    ),
                  ),
                );
              }),
              const Divider(height: 32),
              _summaryRow('Items subtotal', '\u20A6${format.format(state.total)}'),
              ...storeGroups.keys.map((storeId) {
                final type = _storeDeliveryType[storeId] ?? 'negotiate';
                final storeName = _storeNames[storeId] ?? 'Store';
                if (type == 'free') {
                  return _summaryRow('Delivery ($storeName)', 'FREE \uD83C\uDF81', valueColor: AppColors.primaryGreen);
                }
                final fee = _storeDeliveryFee[storeId] ?? 0;
                final contribution = _storeDeliveryContribution[storeId] ?? 0;
                if (type == 'courier') {
                  final courier = _storeCourier[storeId];
                  return _summaryRow(
                    '\uD83D\uDE9A ${courier?.name ?? 'Courier'} ($storeName)',
                    '\u20A6${format.format(fee)}',
                  );
                }
                if (_storeDeliveryAgreed[storeId] != true) {
                  return _summaryRow('Delivery ($storeName)', 'Not agreed yet', valueColor: Colors.orange[800]);
                }
                if (type == 'split' && contribution > 0) {
                  return Column(
                    children: [
                      _summaryRow('Delivery ($storeName, your share)', '\u20A6${format.format(fee)}'),
                      _summaryRow('Delivery ($storeName, vendor covers)',
                          '-\u20A6${format.format(contribution)}', valueColor: AppColors.primaryGreen),
                    ],
                  );
                }
                return _summaryRow('Delivery ($storeName)', '\u20A6${format.format(fee)}');
              }),
              const Divider(height: 20),
              _summaryRow(
                'Total',
                '\u20A6${format.format(totalWithDelivery)}',
                isBold: true,
                fontSize: 18,
                valueColor: AppColors.primaryGreen,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.lock, size: 14, color: Colors.grey[600]),
                  const SizedBox(width: 4),
                  Text('All amounts held securely in escrow',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                ],
              ),
              if (deliveryUnagreed) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange[50],
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.orange[300]!),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.orange[700]),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Courier delivery isn\'t available for ${unagreedStoreNames.join(', ')} right now. '
                          'Chat with the vendor to arrange a delivery fee, or remove those items to check out.',
                          style: TextStyle(color: Colors.orange[800], fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Kay's Credit section
              if (_creditBalance > 0) ...[
                const SizedBox(height: 16),
                Card(
                  color: AppColors.primaryGreen.withAlpha(10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text("⚡", style: TextStyle(fontSize: 20)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("Kay's Credit", style: TextStyle(fontWeight: FontWeight.bold)),
                                  Text('Balance: \u20A6${format.format(_creditBalance)}',
                                      style: const TextStyle(fontSize: 13, color: AppColors.mediumGray)),
                                  if (!canUseCreditFully)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 2),
                                      child: Text(
                                        'Not enough to cover this order yet \u2014 partial credit payment isn\'t supported',
                                        style: TextStyle(fontSize: 11, color: AppColors.mediumGray),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Switch(
                              value: _useCredit && canUseCreditFully && !_hasCourierDelivery,
                              onChanged: (canUseCreditFully && !_hasCourierDelivery)
                                  ? (val) => setState(() => _useCredit = val)
                                  : null,
                              activeColor: AppColors.primaryGreen,
                            ),
                          ],
                        ),
                        if (_useCredit && canUseCreditFully) ...[
                          const Divider(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Order Total'),
                              Text('\u20A6${format.format(totalWithDelivery)}'),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Kay's Credit", style: TextStyle(color: AppColors.primaryGreen)),
                              Text('-\u20A6${format.format(creditToUse)}',
                                  style: const TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const Divider(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('To Pay', style: TextStyle(fontWeight: FontWeight.bold)),
                              Text('\u20A6${format.format(amountToPay)}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.primaryGreen)),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 24),
              const Text('Payment', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.security, color: AppColors.escrowBlue),
                  title: const Text('Escrow Protection'),
                  subtitle: Text(
                    storeGroups.length == 1
                        ? 'Payment held until you confirm delivery'
                        : 'Each vendor paid separately on delivery confirmation',
                  ),
                  trailing: const Icon(Icons.check_circle, color: AppColors.successGreen),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: (_isPayingWithCredit || _isPayingWithWallet || deliveryUnagreed)
                      ? null
                      : () async {
                          // KYC gate — a buyer must verify their NIN before buying.
                          if (!await requireKyc(context)) return;
                          if (!context.mounted) return;
                          if (creditCoversFull) {
                            _completeWithCredit(totalWithDelivery);
                          } else {
                            _completeWithWallet(totalWithDelivery);
                          }
                        },
                  icon: (_isPayingWithCredit || _isPayingWithWallet)
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(creditCoversFull ? Icons.check_circle : Icons.account_balance_wallet),
                  label: Text(creditCoversFull
                      ? 'Complete with Credit'
                      : 'Pay \u20A6${format.format(amountToPay)} from Wallet'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                creditCoversFull
                    ? 'Full order covered by Kay\'s Credit'
                    : 'Paid from your wallet • held in escrow until delivery',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.mediumGray, fontSize: 12),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _summaryRow(
    String label,
    String value, {
    Color? valueColor,
    bool isBold = false,
    double fontSize = 14,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: fontSize, color: isBold ? AppColors.charcoal : AppColors.mediumGray)),
          Text(
            value,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
              color: valueColor ?? AppColors.charcoal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _deliveryAddressSection() {
    final addr = _selectedAddress;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5EB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primaryGreen),
      ),
      child: Row(
        children: [
          const Icon(Icons.location_on, color: AppColors.primaryGreen),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  addr == null ? 'Add a delivery address' : '${addr.label} • ${addr.city}',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.primaryGreen),
                ),
                const SizedBox(height: 2),
                Text(
                  addr == null ? 'Needed to show courier delivery prices' : addr.address,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _changeAddress,
            child: Text(addr == null ? 'Add' : 'Change'),
          ),
        ],
      ),
    );
  }

  /// Courier picker for one store. Hidden unless that store has live rates;
  /// loading shows a spinner. When no courier covers the route the existing
  /// free/negotiate summary handles delivery, so nothing is shown here.
  Widget _courierSelector(String storeId) {
    final format = NumberFormat('#,##0');
    if (_storeQuoteLoading[storeId] == true) {
      return const Padding(
        padding: EdgeInsets.only(top: 10),
        child: Row(
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryGreen)),
            SizedBox(width: 10),
            Text('Getting delivery prices...', style: TextStyle(fontSize: 12, color: AppColors.mediumGray)),
          ],
        ),
      );
    }

    final quote = _storeQuotes[storeId];
    if (quote == null || !quote.hasCouriers) return const SizedBox.shrink();
    final selected = _storeCourier[storeId];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        const Text('🚚 Choose Delivery', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 8),
        ...quote.couriers.map((courier) {
          final isSelected = selected?.name == courier.name;
          return GestureDetector(
            onTap: () => _selectCourier(storeId, courier),
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFFE8F5EB) : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected ? AppColors.primaryGreen : Colors.grey[300]!,
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: isSelected ? AppColors.primaryGreen : AppColors.mediumGray, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(courier.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        if (courier.eta != null && courier.eta!.isNotEmpty)
                          Text(courier.eta!, style: const TextStyle(fontSize: 11, color: AppColors.mediumGray)),
                      ],
                    ),
                  ),
                  Text('₦${format.format(courier.fee)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.primaryGreen)),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  bool _isPayingWithCredit = false;
  bool _isPayingWithWallet = false;

  Future<void> _completeWithCredit(double total) async {
    if (_buyerId.isEmpty || _isPayingWithCredit) return;
    setState(() => _isPayingWithCredit = true);

    try {
      final cartState = context.read<CartCubit>().state;

      // Group cart items by vendor (one vendor order per store), mirroring
      // the same grouping used for card checkout (payment_simulation_screen).
      final Map<String, List<Map<String, dynamic>>> vendorItemGroups = {};
      final Map<String, String> vendorStoreMap = {};

      for (final item in cartState.items) {
        final product = cartState.productMap[item.productId];
        if (product == null) continue;
        final storeId = product.storeId;
        if (storeId.isEmpty) continue;

        String vendorId = '';
        final cachedStore = context.read<MarketplaceCubit>().state.stores[storeId];
        if (cachedStore != null) {
          vendorId = cachedStore.vendorId;
        } else {
          try {
            final storeData = await SupabaseService.client
                .from('stores')
                .select('id, vendor_id')
                .eq('id', storeId)
                .maybeSingle();
            if (storeData != null) vendorId = storeData['vendor_id'] as String;
          } catch (_) {}
        }
        if (vendorId.isEmpty) continue;

        vendorStoreMap[vendorId] = storeId;
        final unitPrice = item.variantPrice ?? product.price;
        final itemData = <String, dynamic>{
          'product_id': product.id,
          'name': product.name,
          'price': unitPrice,
          'quantity': item.quantity,
        };
        if (item.variantLabel != null) itemData['variant_label'] = item.variantLabel;
        vendorItemGroups.putIfAbsent(vendorId, () => []).add(itemData);
      }

      if (vendorItemGroups.isEmpty) {
        if (mounted) {
          setState(() => _isPayingWithCredit = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No valid items found for checkout'), backgroundColor: AppColors.errorRed),
          );
        }
        return;
      }

      final vendorOrders = vendorItemGroups.entries
          .map((e) => {
                'vendor_id': e.key,
                'store_id': vendorStoreMap[e.key] ?? '',
                'items': e.value,
              })
          .toList();

      await CreditService.completeCreditOrder(buyerId: _buyerId, vendorOrders: vendorOrders);

      if (!mounted) return;
      await context.read<CartCubit>().clearCart(_buyerId);

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: AppColors.successGreen, size: 64),
          title: const Text('Order Complete'),
          content: Text('Paid with Kay\'s Credit.\nTotal: \u20A6${NumberFormat('#,##0').format(total)}'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: AppColors.errorRed),
        );
      }
    } finally {
      if (mounted) setState(() => _isPayingWithCredit = false);
    }
  }

  /// Pay the whole order from the buyer's wallet. Builds one vendor order per
  /// store (mirroring the credit + card paths) with any courier selection
  /// attached, then calls wallet-checkout. If the balance is short, offers to
  /// top up.
  Future<void> _completeWithWallet(double total) async {
    if (_buyerId.isEmpty || _isPayingWithWallet) return;
    setState(() => _isPayingWithWallet = true);

    try {
      final cartState = context.read<CartCubit>().state;

      final Map<String, List<Map<String, dynamic>>> vendorItemGroups = {};
      final Map<String, String> vendorStoreMap = {};

      for (final item in cartState.items) {
        final product = cartState.productMap[item.productId];
        if (product == null) continue;
        final storeId = product.storeId;
        if (storeId.isEmpty) continue;

        String vendorId = '';
        final cachedStore = context.read<MarketplaceCubit>().state.stores[storeId];
        if (cachedStore != null) {
          vendorId = cachedStore.vendorId;
        } else {
          try {
            final storeData = await SupabaseService.client
                .from('stores')
                .select('id, vendor_id')
                .eq('id', storeId)
                .maybeSingle();
            if (storeData != null) vendorId = storeData['vendor_id'] as String;
          } catch (_) {}
        }
        if (vendorId.isEmpty) continue;

        vendorStoreMap[vendorId] = storeId;
        final unitPrice = item.variantPrice ?? product.price;
        final itemData = <String, dynamic>{
          'product_id': product.id,
          'name': product.name,
          'price': unitPrice,
          'quantity': item.quantity,
        };
        if (item.variantLabel != null) itemData['variant_label'] = item.variantLabel;
        vendorItemGroups.putIfAbsent(vendorId, () => []).add(itemData);
      }

      if (vendorItemGroups.isEmpty) {
        if (mounted) {
          setState(() => _isPayingWithWallet = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No valid items found for checkout'), backgroundColor: AppColors.errorRed),
          );
        }
        return;
      }

      final courierSelections = _buildCourierSelections();
      final vendorOrders = vendorItemGroups.entries.map((e) {
        final storeId = vendorStoreMap[e.key] ?? '';
        final courier = courierSelections[storeId];
        return <String, dynamic>{
          'vendor_id': e.key,
          'store_id': storeId,
          'items': e.value,
          if (courier != null) 'delivery_quote_id': courier['quote_id'],
          if (courier != null) 'selected_courier_name': courier['courier_name'],
          if (courier != null && courier['option_ref'] != null) 'selected_option_ref': courier['option_ref'],
        };
      }).toList();

      await WalletService.checkout(buyerId: _buyerId, vendorOrders: vendorOrders);

      if (!mounted) return;
      await context.read<CartCubit>().clearCart(_buyerId);

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: AppColors.successGreen, size: 64),
          title: const Text('Order Complete'),
          content: Text('Paid from your wallet.\nTotal: ₦${NumberFormat('#,##0').format(total)}'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } on WalletInsufficient catch (e) {
      if (!mounted) return;
      final fmt = NumberFormat('#,##0');
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Not enough wallet balance'),
          content: Text(
            'Your wallet has ₦${fmt.format(e.balance)} but this order is ₦${fmt.format(e.required)}.\n'
            'Add ₦${fmt.format(e.shortfall)} to continue.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const AddMoneyScreen()));
              },
              child: const Text('Add money'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: AppColors.errorRed),
        );
      }
    } finally {
      if (mounted) setState(() => _isPayingWithWallet = false);
    }
  }
}
