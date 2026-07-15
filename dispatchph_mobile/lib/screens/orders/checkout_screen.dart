import 'package:flutter/material.dart';
import '../../core/services/error_text.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/models/delivery_models.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/credit_service.dart';
import '../../core/services/wallet_service.dart';
import '../../core/services/payment_service.dart';
import '../../core/services/delivery_service.dart';
import '../../widgets/rider_searching_indicator.dart';
import '../delivery/buyer_addresses_screen.dart';
import '../chat/chat_screen.dart';
import '../wallet/add_money_screen.dart';
import 'flutterwave_checkout_screen.dart';

class CheckoutScreen extends StatefulWidget {
  /// When set, check out ONLY this product (a single-product "Buy Now"),
  /// leaving the buyer's other cart items untouched. Null = whole-cart checkout.
  final String? onlyProductId;

  const CheckoutScreen({super.key, this.onlyProductId});

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
  // Stable key for this checkout session so a timeout-then-retry of wallet
  // payment reuses the same reference and can't double-charge (server dedupes).
  final String _walletCheckoutKey = const Uuid().v4();
  // Whether each store's courier-quote search has definitively finished — found
  // couriers, genuine zero-coverage, or errored after all retries. Lets us tell
  // "still searching / not yet tried" apart from "searched, none available", so
  // the no-courier warning only shows once the search has truly completed.
  final Map<String, bool> _storeQuoteResolved = {};
  BuyerAddress? _selectedAddress;
  bool _loaded = false;
  bool _useCredit = false;
  double _creditBalance = 0;
  String _buyerId = '';

  bool get _hasCourierDelivery => _storeCourier.values.any((c) => c != null);

  // When onlyProductId is set (single-product "Buy Now"), the whole checkout —
  // display, totals, delivery quotes, orders, and the post-payment cart clear —
  // works on just that product's cart line, so the rest of the cart is left
  // intact. Null = normal whole-cart checkout.
  List<CartItem> _scopedItems(CartState s) => widget.onlyProductId == null
      ? s.items
      : s.items.where((i) => i.productId == widget.onlyProductId).toList();

  double _scopedTotal(CartState s) {
    if (widget.onlyProductId == null) return s.total;
    double t = 0;
    for (final i in _scopedItems(s)) {
      final unit = i.variantPrice ?? s.productMap[i.productId]?.price ?? 0;
      t += unit * i.quantity;
    }
    return t;
  }

  /// Clear only what was checked out: the whole cart normally, or just the
  /// single "Buy Now" product's line when scoped.
  Future<void> _clearCheckedOut() async {
    if (widget.onlyProductId == null) {
      await _clearCheckedOut();
    } else {
      final ids = context
          .read<CartCubit>()
          .state
          .items
          .where((i) => i.productId == widget.onlyProductId)
          .map((i) => i.id)
          .toList();
      await context.read<CartCubit>().removeItems(ids, _buyerId);
    }
  }

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
    final storeIds = _scopedItems(cartState)
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
        final firstItem = _scopedItems(cartState).firstWhere(
          (i) => cartState.productMap[i.productId]?.storeId == storeId,
        );
        final deliveryType = cartState.productMap[firstItem.productId]?.deliveryType ?? 'courier';
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

        // A negotiated fee is only valid for a short window. A stale one — left
        // over from a previous order, or accepted long ago and never paid —
        // must NOT show as the default; the buyer re-negotiates a fresh fee.
        // (The server enforces the same window at checkout.)
        final acceptedAt = accepted != null
            ? DateTime.tryParse(accepted['created_at'] as String? ?? '')
            : null;
        final feeFresh = acceptedAt != null &&
            DateTime.now().difference(acceptedAt) <= const Duration(minutes: 60);
        if (accepted != null && feeFresh) {
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

  // Courier quote retry policy: total attempts before giving up and showing the
  // "no courier available" fallback. Only transient failures consume retries.
  static const int _quoteMaxAttempts = 3;

  /// True when an empty quote looks like a transient provider/network failure
  /// (worth retrying) rather than a genuine "no courier covers this route". A
  /// provider that errors/times out inside the edge function comes back as an
  /// empty list with an error reason (allSettled), which is indistinguishable
  /// from real no-coverage without inspecting the reason string.
  bool _isTransientQuoteFailure(String? reason) {
    if (reason == null || reason.isEmpty) return true;
    final r = reason.toLowerCase();
    return r.contains('error') ||
        r.contains('timeout') ||
        r.contains('timed out') ||
        r.contains('network') ||
        r.contains('econn') ||
        RegExp(r'\b5\d\d\b').hasMatch(r);
  }

  /// Fetch Shipbubble courier rates for every store using the selected delivery
  /// address. When a store has couriers, courier becomes its delivery method
  /// (cheapest pre-selected); otherwise the free/negotiate fallback stands.
  Future<void> _loadQuotes() async {
    final addr = _selectedAddress;
    if (addr == null || _buyerId.isEmpty) return;

    final cartState = context.read<CartCubit>().state;
    final storeIds = _scopedItems(cartState)
        .map((i) => cartState.productMap[i.productId]?.storeId)
        .whereType<String>()
        .toSet();

    // Fetch every store's courier rates CONCURRENTLY instead of one-by-one —
    // with several vendors this collapses N sequential round-trips into a single
    // wait, so "searching for riders" takes about as long as the slowest store,
    // not the sum of them all.
    await Future.wait(
      storeIds.map((storeId) => _loadQuoteForStore(storeId, addr)),
    );
  }

  /// Fetch courier rates for ONE store and fold the result into state. Runs
  /// concurrently with the other stores (see [_loadQuotes]).
  Future<void> _loadQuoteForStore(String storeId, BuyerAddress addr) async {
    final vendorId = _storeVendorIds[storeId];
    if (vendorId == null) return;
    // A vendor offering free delivery handles it themselves — no courier.
    if (_storeDeliveryType[storeId] == 'free') return;

    final cartState = context.read<CartCubit>().state;
    // Items for this store, in the shape get-delivery-quotes expects.
    final items = _scopedItems(cartState)
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

    if (mounted) {
      setState(() {
        _storeQuoteLoading[storeId] = true;
        _storeQuoteResolved[storeId] = false;
      });
    }

    // Auto-retry transient failures (network/API error, provider timeout). A
    // valid "no courier covers this route" result is NOT retried — retrying
    // won't change coverage — so it falls straight through to the warning.
    DeliveryQuote? quote;
    for (var attempt = 1; attempt <= _quoteMaxAttempts; attempt++) {
      try {
        final q = await DeliveryService.getDeliveryQuotes(
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
        quote = q;
        // Stop once we have couriers or a genuine (non-transient) empty
        // result; only transient provider failures consume another attempt.
        if (q.hasCouriers || !_isTransientQuoteFailure(q.reason)) break;
      } catch (e) {
        debugPrint('[Checkout] quote attempt $attempt error for $storeId: $e');
      }
      if (attempt < _quoteMaxAttempts) {
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }

    if (!mounted) return;
    setState(() {
      _storeQuoteLoading[storeId] = false;
      _storeQuoteResolved[storeId] = true;
      if (quote != null && quote.hasCouriers) {
        // Server returns options fastest-first (price as tiebreak), so the
        // first option is the fastest — pre-select it as the default.
        final preferred = quote.couriers.first;
        _storeQuotes[storeId] = quote;
        _storeCourier[storeId] = preferred;
        _storeDeliveryType[storeId] = 'courier';
        _storeDeliveryFee[storeId] = preferred.fee;
        _storeDeliveryContribution[storeId] = 0;
        _storeDeliveryAgreed[storeId] = true;
      }
    });
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
      _storeQuoteResolved.clear();
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
          if (_scopedItems(state).isEmpty) {
            return const Center(child: Text('Cart is empty'));
          }

          final Map<String, List<CartItem>> storeGroups = {};
          for (final item in _scopedItems(state)) {
            final product = state.productMap[item.productId];
            if (product == null) continue;
            storeGroups.putIfAbsent(product.storeId, () => []).add(item);
          }

          final totalDeliveryFee = storeGroups.keys.fold<double>(0, (sum, id) => sum + (_storeDeliveryFee[id] ?? 0));
          final totalVendorContribution =
              storeGroups.keys.fold<double>(0, (sum, id) => sum + (_storeDeliveryContribution[id] ?? 0));
          final totalWithDelivery = _scopedTotal(state) + totalDeliveryFee;
          // Gates the pay button: any store without an agreed delivery — including
          // while its quote is still loading — blocks checkout.
          final deliveryUnagreed = storeGroups.keys.any((id) => _storeDeliveryAgreed[id] != true);
          // Drives the "no courier available, contact vendor" warning. Unlike the
          // button gate, this only fires for stores whose quote search has fully
          // resolved with no courier — never while still loading/retrying — so the
          // warning can't flash before the search actually returns zero.
          final unavailableStoreNames = storeGroups.keys
              .where((id) =>
                  _storeDeliveryAgreed[id] != true &&
                  _storeQuoteResolved[id] == true &&
                  _storeQuoteLoading[id] != true)
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
              if (deliveryUnagreed) _deliveryHelpBanner(),
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
              _summaryRow('Items subtotal', '\u20A6${format.format(_scopedTotal(state))}'),
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
              if (unavailableStoreNames.isNotEmpty) ...[
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
                          'Courier delivery isn\'t available for ${unavailableStoreNames.join(', ')} right now. '
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
                  onPressed: (_isPayingWithCredit || _isPayingWithWallet)
                      ? null
                      : () {
                          if (deliveryUnagreed) {
                            _showDeliveryBlockedSnack();
                            return;
                          }
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
              // Card / bank transfer (Flutterwave). Only shown when Kay's Credit
              // doesn't already cover the full order — otherwise the button above
              // completes for free. No NIN needed: money flows FROM the buyer.
              if (!creditCoversFull) ...[
                const SizedBox(height: 12),
                Row(
                  children: const [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('or', style: TextStyle(color: AppColors.mediumGray)),
                    ),
                    Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isPayingWithCard
                        ? null
                        : () {
                            if (deliveryUnagreed) {
                              _showDeliveryBlockedSnack();
                              return;
                            }
                            _completeWithCard(totalWithDelivery, '');
                          },
                    icon: _isPayingWithCard
                        ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryGreen))
                        : const Icon(Icons.credit_card),
                    label: Text('Pay ₦${format.format(totalWithDelivery)} online'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primaryGreen,
                      side: const BorderSide(color: AppColors.primaryGreen),
                      padding: const EdgeInsets.symmetric(vertical: 18),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  "Opens on card — tap “Change payment method” for transfer, USSD or eNaira • held in escrow",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.mediumGray, fontSize: 12),
                ),
              ],
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

  // Explains WHY the buyer can't pay yet, with the exact fix per store:
  //  • no delivery address  → "Add address" (needed to price a courier)
  //  • address set, but a store has no courier coverage → "Message vendor"
  Widget _deliveryHelpBanner() {
    // No address yet — the buyer must add one before any courier can be priced.
    if (_selectedAddress == null) {
      return _deliveryPromptCard(
        icon: Icons.location_on,
        color: AppColors.warningOrange,
        title: 'Add your delivery address',
        body: "We need it to show courier prices and let you pay.",
        buttonLabel: 'Add address',
        onTap: _changeAddress,
      );
    }
    // Address set — flag any store whose courier search finished with no cover.
    final blocked = _storeNames.keys.where((id) =>
        _storeDeliveryAgreed[id] != true &&
        _storeQuoteResolved[id] == true &&
        _storeQuoteLoading[id] != true);
    if (blocked.isEmpty) return const SizedBox.shrink();
    return Column(
      children: blocked
          .map((id) => _deliveryPromptCard(
                icon: Icons.local_shipping,
                color: AppColors.errorRed,
                title: 'No courier for ${_storeNames[id] ?? 'this vendor'}',
                body: 'No courier covers this route. Message the vendor to arrange delivery.',
                buttonLabel: 'Message vendor',
                onTap: () => _messageVendor(id),
              ))
          .toList(),
    );
  }

  Widget _deliveryPromptCard({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
    required String buttonLabel,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 13)),
                const SizedBox(height: 2),
                Text(body, style: const TextStyle(fontSize: 12, color: AppColors.charcoal)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: onTap,
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            child: Text(buttonLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _messageVendor(String storeId) {
    final vendorId = _storeVendorIds[storeId];
    if (vendorId == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          orderId: 'product_$storeId',
          buyerId: _buyerId,
          vendorId: vendorId,
          vendorName: _storeNames[storeId] ?? 'Vendor',
          buyerName: 'You',
        ),
      ),
    );
  }

  // Immediate, unmissable feedback when the buyer taps a blocked Pay button —
  // a centre-screen dialog (not a bottom snackbar they might miss) with the fix.
  void _showDeliveryBlockedSnack() {
    final noAddress = _selectedAddress == null;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(noAddress ? Icons.location_on : Icons.local_shipping,
            color: AppColors.warningOrange, size: 44),
        title: Text(noAddress ? 'Add your delivery address' : 'Delivery not arranged yet'),
        content: Text(
          noAddress
              ? 'You need a delivery address before you can pay — it lets us show courier prices and deliver your order.'
              : 'Some items have no courier available for your area. Message the vendor to arrange delivery, then come back and pay.',
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Not now')),
          if (noAddress)
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _changeAddress();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryGreen,
                foregroundColor: Colors.white,
              ),
              child: const Text('Add address'),
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
      return const RiderSearchingIndicator();
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
          // Match on optionRef (unique per rate) so two options from the same
          // courier (e.g. Chowdeck standard vs same-day) don't both highlight.
          // Fallback to name+fee for options without a ref (free/negotiate).
          final isSelected = selected != null &&
              (courier.optionRef != null
                  ? selected.optionRef == courier.optionRef
                  : selected.name == courier.name && selected.fee == courier.fee);
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
                        Row(
                          children: [
                            Flexible(
                              child: Text(courier.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            ),
                            // TEMP DEBUG: shows which delivery company (provider)
                            // returned this rider, to confirm BOTH companies are
                            // populating. Remove before the production release.
                            if (courier.provider != null) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: courier.provider == 'terminal'
                                      ? const Color(0xFFFFF0E0)
                                      : const Color(0xFFE0F0FF),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  courier.provider!,
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                    color: courier.provider == 'terminal'
                                        ? const Color(0xFFB35A00)
                                        : const Color(0xFF0066B3),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
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
  bool _isPayingWithCard = false;

  /// Any payment method currently in flight. Handlers check this to block a
  /// second payment starting, so we don't need to visually disable every button
  /// when one is tapped (which looked like both buttons were being pressed).
  bool get _paymentInFlight => _isPayingWithCredit || _isPayingWithWallet || _isPayingWithCard;

  Future<void> _completeWithCredit(double total) async {
    if (_buyerId.isEmpty || _paymentInFlight) return;
    setState(() => _isPayingWithCredit = true);

    try {
      final cartState = context.read<CartCubit>().state;

      // Group cart items by vendor (one vendor order per store), mirroring
      // the same grouping used for card checkout (payment_simulation_screen).
      final Map<String, List<Map<String, dynamic>>> vendorItemGroups = {};
      final Map<String, String> vendorStoreMap = {};

      for (final item in _scopedItems(cartState)) {
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
      await _clearCheckedOut();

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
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.errorRed),
        );
      }
    } finally {
      if (mounted) setState(() => _isPayingWithCredit = false);
    }
  }

  /// Build one vendor order per store from the current cart, attaching any
  /// courier selection. Shared by the wallet and card/transfer paths so both
  /// send an identical shape to the server (which re-derives prices anyway).
  /// Returns null (and shows a snackbar) if no valid items are found.
  Future<List<Map<String, dynamic>>?> _buildVendorOrders() async {
    final cartState = context.read<CartCubit>().state;

    final Map<String, List<Map<String, dynamic>>> vendorItemGroups = {};
    final Map<String, String> vendorStoreMap = {};

    for (final item in _scopedItems(cartState)) {
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No valid items found for checkout'), backgroundColor: AppColors.errorRed),
        );
      }
      return null;
    }

    final courierSelections = _buildCourierSelections();
    return vendorItemGroups.entries.map((e) {
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
  }

  /// Pay the whole order via Flutterwave (card + bank transfer + USSD). The
  /// server (prepare-checkout) re-derives prices/delivery and returns a hosted
  /// payment link; we open it in a webview. flutterwave-webhook creates the
  /// orders + escrow once the charge completes — this path never touches money
  /// client-side.
  /// Open Flutterwave's inline checkout. With an empty [paymentOption] the buyer
  /// sees Flutterwave's full "Payment Methods" list (card, transfer, USSD, eNaira,
  /// …) all selectable and picks one there.
  Future<void> _completeWithCard(double total, String paymentOption) async {
    if (_buyerId.isEmpty || _paymentInFlight) return;
    setState(() => _isPayingWithCard = true);

    try {
      final vendorOrders = await _buildVendorOrders();
      if (vendorOrders == null) return;

      final res = await PaymentService.prepareCheckout(
        buyerId: _buyerId,
        vendorOrders: vendorOrders,
        paymentOption: paymentOption,
      );
      final txRef = res['tx_ref'] as String?;
      final publicKey = res['public_key'] as String?;
      final amount = (res['amount'] as num?)?.toDouble() ?? total;
      final redirectUrl = res['redirect_url'] as String? ?? 'https://kaysmarket-legal.web.app/payment-complete';
      final customer = (res['customer'] as Map?)?.cast<String, dynamic>() ?? {};
      if (txRef == null || txRef.isEmpty || publicKey == null || publicKey.isEmpty) {
        throw Exception("We couldn't start your payment. Please try again.");
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FlutterwaveCheckoutScreen(
            publicKey: publicKey,
            txRef: txRef,
            buyerId: _buyerId,
            total: amount,
            redirectUrl: redirectUrl,
            paymentOption: paymentOption,
            email: customer['email'] as String? ?? '',
            name: customer['name'] as String? ?? '',
            phone: customer['phone'] as String? ?? '',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.errorRed),
        );
      }
    } finally {
      if (mounted) setState(() => _isPayingWithCard = false);
    }
  }

  /// Pay the whole order from the buyer's wallet. Builds one vendor order per
  /// store (mirroring the credit + card paths) with any courier selection
  /// attached, then calls wallet-checkout. If the balance is short, offers to
  /// top up.
  Future<void> _completeWithWallet(double total) async {
    if (_buyerId.isEmpty || _paymentInFlight) return;
    setState(() => _isPayingWithWallet = true);

    try {
      final vendorOrders = await _buildVendorOrders();
      if (vendorOrders == null) {
        if (mounted) setState(() => _isPayingWithWallet = false);
        return;
      }

      await WalletService.checkout(
        buyerId: _buyerId,
        vendorOrders: vendorOrders,
        idempotencyKey: _walletCheckoutKey,
      );

      if (!mounted) return;
      await _clearCheckedOut();

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
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.errorRed),
        );
      }
    } finally {
      if (mounted) setState(() => _isPayingWithWallet = false);
    }
  }
}
