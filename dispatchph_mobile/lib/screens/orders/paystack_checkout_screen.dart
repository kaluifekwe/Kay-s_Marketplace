import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/services/payment_service.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/push_service.dart';
import '../../core/models/models.dart';
import '../marketplace/home_screen.dart';

class PaystackCheckoutScreen extends StatefulWidget {
  final String authorizationUrl;
  final String reference;
  final String orderId;
  final String buyerId;
  final List<Map<String, dynamic>> vendorOrders;
  final double total;
  final String email;

  const PaystackCheckoutScreen({
    super.key,
    required this.authorizationUrl,
    required this.reference,
    required this.orderId,
    required this.buyerId,
    required this.vendorOrders,
    required this.total,
    required this.email,
  });

  @override
  State<PaystackCheckoutScreen> createState() => _PaystackCheckoutScreenState();
}

class _PaystackCheckoutScreenState extends State<PaystackCheckoutScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _paymentHandled = false;
  bool _hasError = false;
  Timer? _pollTimer;

  static const _validPaystackHosts = [
    'checkout.paystack.com',
    'paystack.com',
  ];

  bool _isValidPaystackUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return _validPaystackHosts.any((host) =>
          uri.host == host || uri.host.endsWith('.$host'));
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();

    if (!widget.authorizationUrl.startsWith('http') ||
        !_isValidPaystackUrl(widget.authorizationUrl)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showErrorAndGoBack('Invalid payment URL. Please try again.');
        }
      });
      return;
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          if (mounted) setState(() => _isLoading = true);
        },
        onPageFinished: (url) {
          if (mounted) setState(() => _isLoading = false);
          _checkForErrorPage();
        },
        onNavigationRequest: (request) {
          final url = request.url;
          final uri = Uri.tryParse(url);

          if (uri != null && (uri.queryParameters.containsKey('trxref') ||
              uri.queryParameters.containsKey('reference'))) {
            print('[PaystackCheckout] Payment success detected: $url');
            _handlePaymentSuccess();
            return NavigationDecision.prevent;
          }

          if (url.contains('success') ||
              url.contains('callback') ||
              url.contains('khamsa')) {
            _handlePaymentSuccess();
            return NavigationDecision.prevent;
          }

          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.authorizationUrl));

    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkPaymentStatus());
  }

  void _checkForErrorPage() {
    if (_paymentHandled || _hasError) return;
    _controller.currentUrl().then((url) {
      if (url != null && !_isValidPaystackUrl(url) && mounted) {
        _showErrorAndGoBack('Payment page failed to load. Please try again.');
      }
    }).catchError((_) {});
  }

  void _showErrorAndGoBack(String message) {
    if (!mounted) return;
    setState(() => _hasError = true);
    _pollTimer?.cancel();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.error_outline, color: AppColors.errorRed, size: 48),
        title: const Text('Payment Error'),
        content: Text(message),
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
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkPaymentStatus() async {
    if (_paymentHandled) return;

    try {
      final transactions = await PaymentService.getTransactions(widget.orderId);
      final successTx = transactions.where(
        (tx) => tx['status'] == 'success' && tx['type'] == 'payment',
      ).isNotEmpty;

      if (successTx) {
        _handlePaymentSuccess();
      }
    } catch (_) {}
  }

  Future<void> _handlePaymentSuccess() async {
    if (_paymentHandled) return;
    _paymentHandled = true;
    _pollTimer?.cancel();

    try {
      // Notify each vendor
      for (final vendorOrder in widget.vendorOrders) {
        final vendorId = vendorOrder['vendor_id'] as String;
        final subtotal = (vendorOrder['subtotal'] as num).toDouble();
        if (vendorId.isNotEmpty) {
          PushService.sendPush(
            userId: vendorId,
            title: 'New Order!',
            body: 'You received a new order of \u20A6${subtotal.toStringAsFixed(0)}',
            data: {'type': 'order', 'orderId': widget.orderId},
          );
        }
      }

      await context.read<CartCubit>().clearCart(widget.buyerId);
    } catch (e) {
      print('[PaystackCheckout] Post-payment error: $e');
    }

    if (!mounted) return;

    final vendorCount = widget.vendorOrders.length;
    final vendorText = vendorCount == 1 ? 'The vendor' : '$vendorCount vendors';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: AppColors.successGreen, size: 64),
        title: const Text('Payment Successful'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Your payment is held in escrow.'),
            const SizedBox(height: 8),
            Text(
              '\u20A6${widget.total.toStringAsFixed(0)}',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryGreen,
              ),
            ),
            const SizedBox(height: 8),
            Text('$vendorText will process your order.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const MarketplaceHome(initialIndex: 2)),
                (route) => false,
              );
            },
            child: const Text('View Orders'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Complete Payment'),
        backgroundColor: AppColors.primaryGreen,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Cancel Payment?'),
                content: const Text('Your payment has not been completed. You can try again later.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Continue Paying'),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.pop(context);
                    },
                    child: const Text('Cancel', style: TextStyle(color: AppColors.errorRed)),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      body: Stack(
        children: [
          if (!_hasError)
            WebViewWidget(controller: _controller),
          if (_isLoading && !_hasError)
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: AppColors.primaryGreen),
                  SizedBox(height: 16),
                  Text('Loading payment page...', style: TextStyle(color: AppColors.mediumGray)),
                ],
              ),
            ),
          if (_hasError)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: AppColors.errorRed),
                  const SizedBox(height: 16),
                  const Text('Payment page failed to load',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryGreen),
                    child: const Text('Go Back', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
