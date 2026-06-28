import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/payment_service.dart';
import '../../core/models/models.dart';
import '../marketplace/home_screen.dart';
import 'paystack_checkout_screen.dart';

class PaymentSimulationScreen extends StatefulWidget {
  /// Agreed delivery fee per store, computed by checkout from the latest
  /// accepted chat message for that store's vendor. Keyed by storeId to
  /// match the cart's product->store grouping.
  final Map<String, double> storeDeliveryFees;

  /// Courier chosen per store at checkout: storeId -> { quote_id, courier_name }.
  /// Threaded into create-payment so paystack-webhook can auto-book the courier
  /// after payment. Empty when the order uses free/negotiate delivery.
  final Map<String, Map<String, String>> storeCourierSelections;

  const PaymentSimulationScreen({
    super.key,
    this.storeDeliveryFees = const {},
    this.storeCourierSelections = const {},
  });

  @override
  State<PaymentSimulationScreen> createState() => _PaymentSimulationScreenState();
}

class _PaymentSimulationScreenState extends State<PaymentSimulationScreen> {
  bool _isProcessing = false;
  String _errorMessage = '';

  String _generateUuid() {
    final random = DateTime.now().microsecondsSinceEpoch;
    final hex = random.toRadixString(16).padLeft(32, '0');
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  Future<void> _processPayment() async {
    setState(() {
      _isProcessing = true;
      _errorMessage = '';
    });

    try {
      final cartState = context.read<CartCubit>().state;
      final prefs = await SharedPreferences.getInstance();
      final buyerId = prefs.getString('auth_user_id') ?? '';
      final buyerEmail = prefs.getString('auth_email') ?? '';
      if (buyerId.isEmpty || buyerEmail.isEmpty) {
        setState(() {
          _isProcessing = false;
          _errorMessage = 'Please log in to continue';
        });
        return;
      }

      final hasSession = await PaymentService.ensureSession();
      if (!hasSession) {
        if (mounted) {
          setState(() {
            _isProcessing = false;
            _errorMessage = 'Your session has expired. Please log in again.';
          });
        }
        return;
      }

      // Group cart items by vendor
      final Map<String, List<Map<String, dynamic>>> vendorItemGroups = {};
      final Map<String, String> vendorStoreMap = {};

      for (final item in cartState.items) {
        final product = cartState.productMap[item.productId];
        if (product == null) continue;

        final storeId = product.storeId;
        if (storeId.isEmpty) continue;

        // Resolve vendor_id from store
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
        if (item.variantLabel != null) {
          itemData['variant_label'] = item.variantLabel;
          itemData['variant_price'] = item.variantPrice;
        }

        vendorItemGroups.putIfAbsent(vendorId, () => []).add(itemData);
      }

      if (vendorItemGroups.isEmpty) {
        setState(() {
          _isProcessing = false;
          _errorMessage = 'No valid items found for checkout';
        });
        return;
      }

      // Build vendor_orders array — including each vendor's agreed delivery
      // fee, looked up by checkout from accepted chat messages. The server
      // (create-payment) independently re-verifies this against the chat
      // before charging, so this is only the client's best-effort amount.
      final vendorOrders = <Map<String, dynamic>>[];
      double grandTotal = 0;
      for (final entry in vendorItemGroups.entries) {
        final vendorId = entry.key;
        final items = entry.value;
        final storeId = vendorStoreMap[vendorId] ?? '';
        final subtotal = items.fold<double>(0, (sum, item) {
          final price = (item['price'] as num).toDouble();
          final qty = (item['quantity'] as int);
          return sum + price * qty;
        });
        final deliveryFee = widget.storeDeliveryFees[storeId] ?? 0;
        final vendorOrder = <String, dynamic>{
          'vendor_id': vendorId,
          'store_id': storeId,
          'items': items,
          'subtotal': subtotal,
          'delivery_fee': deliveryFee,
        };
        // If a courier was chosen for this store, thread the quote + courier so
        // create-payment verifies the fee and the webhook books it post-payment.
        final courier = widget.storeCourierSelections[storeId];
        if (courier != null) {
          vendorOrder['delivery_quote_id'] = courier['quote_id'];
          vendorOrder['selected_courier_name'] = courier['courier_name'];
          if (courier['option_ref'] != null) {
            vendorOrder['selected_option_ref'] = courier['option_ref'];
          }
        }
        vendorOrders.add(vendorOrder);
        grandTotal += subtotal + deliveryFee;
      }

      final orderId = _generateUuid();

      final paymentResult = await PaymentService.createPayment(
        orderId: orderId,
        buyerId: buyerId,
        vendorOrders: vendorOrders,
        amount: grandTotal,
        email: buyerEmail,
      );

      if (!mounted) return;

      final paymentUrl = paymentResult['authorization_url'] as String?;
      if (paymentUrl == null ||
          paymentUrl.isEmpty ||
          !paymentUrl.startsWith('http') ||
          !paymentUrl.contains('paystack')) {
        if (mounted) {
          setState(() {
            _isProcessing = false;
            _errorMessage = 'Payment failed to initialize. Please try again.';
          });
        }
        return;
      }

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => PaystackCheckoutScreen(
            authorizationUrl: paymentUrl,
            reference: paymentResult['reference'] ?? '',
            orderId: orderId,
            buyerId: buyerId,
            vendorOrders: vendorOrders,
            total: cartState.total,
            email: buyerEmail,
          ),
        ),
      );
    } catch (e) {
      print('[Payment] Error: $e');
      if (mounted) {
        final rawMsg = e.toString().replaceAll('Exception: ', '');
        String friendlyMsg;
        if (rawMsg.contains('UNAUTHORIZED') ||
            rawMsg.contains('authorization') ||
            rawMsg.contains('Missing authorization')) {
          friendlyMsg = 'Authentication error. Please log in again.';
        } else if (rawMsg.contains('SocketException') ||
            rawMsg.contains('Failed host lookup')) {
          friendlyMsg = 'No internet connection. Please check your network.';
        } else if (rawMsg.contains('timeout')) {
          friendlyMsg = 'Connection timed out. Please try again.';
        } else {
          friendlyMsg = 'Payment failed: $rawMsg';
        }
        setState(() {
          _isProcessing = false;
          _errorMessage = friendlyMsg;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock, size: 64, color: AppColors.escrowBlue),
              const SizedBox(height: 24),
              const Text('Secure Payment', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Your payment will be held securely in escrow until you confirm delivery',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.mediumGray),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.successGreen.withAlpha(15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.successGreen.withAlpha(40)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.shield, color: AppColors.successGreen, size: 18),
                    SizedBox(width: 8),
                    Text('Powered by Paystack', style: TextStyle(color: AppColors.successGreen, fontSize: 13)),
                  ],
                ),
              ),
              if (_errorMessage.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.errorRed.withAlpha(15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _errorMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.errorRed, fontSize: 13),
                  ),
                ),
              ],
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _processPayment,
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.lock_open),
                  label: Text(_isProcessing ? 'Initializing...' : 'Pay with Paystack'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
