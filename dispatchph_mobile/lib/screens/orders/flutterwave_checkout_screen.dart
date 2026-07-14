import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/services/supabase_service.dart';
import '../marketplace/home_screen.dart';

/// Opens the Flutterwave hosted checkout (card + bank transfer + USSD) returned
/// by prepare-checkout, and detects completion two ways:
///  1. the webview navigating to our redirect URL with ?status=successful, and
///  2. polling the pending intent row (transactions.paystack_reference = txRef)
///     which flutterwave-webhook flips to 'success' when it creates the orders.
/// The orders + escrow + notifications are all done server-side by the webhook;
/// this screen just confirms and routes the buyer to their orders.
class FlutterwaveCheckoutScreen extends StatefulWidget {
  final String publicKey;
  final String txRef;
  final String buyerId;
  final double total;
  final String redirectUrl;
  final String paymentOption; // "" = show all methods
  final String email;
  final String name;
  final String phone;

  const FlutterwaveCheckoutScreen({
    super.key,
    required this.publicKey,
    required this.txRef,
    required this.buyerId,
    required this.total,
    required this.redirectUrl,
    required this.paymentOption,
    required this.email,
    required this.name,
    required this.phone,
  });

  @override
  State<FlutterwaveCheckoutScreen> createState() => _FlutterwaveCheckoutScreenState();
}

class _FlutterwaveCheckoutScreenState extends State<FlutterwaveCheckoutScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _handled = false;
  // True once the payment page has redirected back to us reporting success and
  // we're waiting for the webhook to actually create the orders. Drives the
  // "Confirming your payment…" overlay so the buyer isn't left on the raw page.
  bool _verifying = false;
  Timer? _pollTimer;
  DateTime? _verifyStartedAt;

  // Our redirect target (prepare-checkout's FLW_REDIRECT_URL). We only need to
  // recognise it — Flutterwave appends ?status=&tx_ref=&transaction_id=.
  static const _redirectMarker = 'kaysmarket-legal.web.app/payment-complete';
  // How long we wait for the webhook to confirm before telling the buyer their
  // payment is still being confirmed (orders will appear once it lands).
  static const _verifyTimeout = Duration(seconds: 90);

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _isLoading = true);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _isLoading = false);
        },
        onNavigationRequest: (request) {
          final url = request.url;
          if (url.contains(_redirectMarker)) {
            final status = Uri.tryParse(url)?.queryParameters['status']?.toLowerCase() ?? '';
            if (status == 'successful' || status == 'completed') {
              // The redirect is only a HINT — never proof of payment (it's a
              // client-side URL that could be reached without paying). We switch
              // to a verifying state and let the webhook-set DB row be the sole
              // source of truth (see _checkStatus / _finishConfirmed).
              _beginVerifying();
            } else {
              // cancelled / failed — Flutterwave still redirects here.
              _handleCancelled();
            }
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadHtmlString(_buildInlineHtml(), baseUrl: 'https://kaysmarket-legal.web.app');

    // Backup: the webhook flips our intent row to 'success' once orders exist.
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _checkStatus());
  }

  /// Build the page that renders Flutterwave's inline checkout (v3.js). Unlike
  /// the hosted link, the inline SDK honours `payment_options`, so the buyer's
  /// chosen method (card / banktransfer / ussd / enaira) opens directly. On
  /// completion Flutterwave redirects to our redirect_url (detected above); on
  /// close we redirect there with status=cancelled so the screen backs out.
  String _buildInlineHtml() {
    final cfg = <String, dynamic>{
      'public_key': widget.publicKey,
      'tx_ref': widget.txRef,
      'amount': widget.total,
      'currency': 'NGN',
      'redirect_url': widget.redirectUrl,
      // Always pass explicit methods: with a single one the inline SDK opens that
      // method; with the full list it shows a "Payment Methods" screen with ALL
      // selectable. Omitting it makes the SDK default straight to the card form.
      'payment_options': widget.paymentOption.isNotEmpty
          ? widget.paymentOption
          : 'card,banktransfer,ussd,account,enaira,qr',
      'customer': {
        'email': widget.email,
        'name': widget.name,
        'phone_number': widget.phone,
      },
      'customizations': {
        'title': "Kay's Market",
        'description': 'Order payment (held in escrow)',
      },
      'meta': {'tx_ref': widget.txRef},
    };
    final cfgJson = jsonEncode(cfg);
    final redirectJson = jsonEncode(widget.redirectUrl);
    final txRefJson = jsonEncode(widget.txRef);
    return '''<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<script src="https://checkout.flutterwave.com/v3.js"></script>
</head>
<body style="margin:0;background:#ffffff;font-family:-apple-system,Segoe UI,Roboto,sans-serif;">
<div style="padding:48px 24px;text-align:center;color:#6b7280;">Loading secure payment…</div>
<script>
  var cfg = $cfgJson;
  var opened = false;
  function fail(msg){ document.body.innerHTML = '<div style="padding:36px 24px;color:#b00020;font-size:15px;line-height:1.6;">Payment could not start:<br><br>' + msg + '</div>'; }
  // Only treat a close as a cancel if the modal actually opened — otherwise an
  // errored open would silently bounce the buyer back with no explanation.
  cfg.onclose = function(){ if (opened) { window.location.href = $redirectJson + "?status=cancelled&tx_ref=" + $txRefJson; } };
  var tries = 0;
  function start(){
    if (window.FlutterwaveCheckout) {
      try { FlutterwaveCheckout(cfg); opened = true; }
      catch (e) { fail((e && e.message) ? e.message : String(e)); }
    } else if (tries++ < 40) {
      setTimeout(start, 250);
    } else {
      fail('Payment library failed to load. Check your connection and try again.');
    }
  }
  start();
</script>
</body>
</html>''';
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// The buyer's payment page reported success. Flip to the verifying overlay
  /// and check the DB right away instead of waiting for the next poll tick.
  void _beginVerifying() {
    if (_handled || _verifying) return;
    setState(() => _verifying = true);
    _verifyStartedAt = DateTime.now();
    _checkStatus();
  }

  /// The only place success is DECLARED. Reads the intent row that the webhook
  /// flips to 'success' when it has actually created the orders + escrow. If the
  /// buyer reported success but the webhook is slow, we give it _verifyTimeout
  /// before reassuring them their payment is still being confirmed.
  Future<void> _checkStatus() async {
    if (_handled) return;
    try {
      final row = await SupabaseService.client
          .from('transactions')
          .select('status')
          .eq('paystack_reference', widget.txRef)
          .eq('type', 'payment')
          .maybeSingle();
      if (row != null && row['status'] == 'success') {
        _finishConfirmed();
        return;
      }
      // Payment reported by the page but not yet confirmed by the webhook.
      if (_verifying &&
          _verifyStartedAt != null &&
          DateTime.now().difference(_verifyStartedAt!) > _verifyTimeout) {
        _handleConfirmationDelayed();
      }
    } catch (_) {}
  }

  Future<void> _finishConfirmed() async {
    if (_handled) return;
    _handled = true;
    _pollTimer?.cancel();

    try {
      await context.read<CartCubit>().clearCart(widget.buyerId);
    } catch (_) {}

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: AppColors.successGreen, size: 64),
        title: const Text('Payment Successful'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Your payment is held safely in escrow.'),
            const SizedBox(height: 8),
            Text(
              '₦${widget.total.toStringAsFixed(0)}',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.primaryGreen),
            ),
            const SizedBox(height: 8),
            const Text('The vendor will process your order.'),
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

  void _handleCancelled() {
    if (_handled) return;
    _handled = true;
    _pollTimer?.cancel();
    if (!mounted) return;
    // Payment not completed — the intent stays pending (never fulfilled). Send
    // the buyer back to checkout to try again.
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Payment was not completed. You can try again.')),
    );
  }

  /// The buyer paid but the webhook hasn't confirmed within _verifyTimeout
  /// (rare — usually a delayed/queued webhook). We do NOT claim failure: the
  /// money is captured and the orders will be created when the webhook lands.
  /// Reassure the buyer and send them to Orders, where the orders will appear.
  void _handleConfirmationDelayed() {
    if (_handled) return;
    _handled = true;
    _pollTimer?.cancel();
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.hourglass_bottom, color: AppColors.escrowBlue, size: 56),
        title: const Text('Confirming your payment'),
        content: const Text(
          'We received your payment and are finalising your order. '
          'It will appear in My Orders shortly — no need to pay again.',
          textAlign: TextAlign.center,
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
            child: const Text('Go to My Orders'),
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
          // Don't let the buyer bail out mid-confirmation — their money is
          // already captured and the order is being created.
          onPressed: _verifying ? null : () {
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Cancel Payment?'),
                content: const Text('Your payment has not been completed. You can try again later.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Continue Paying')),
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
          WebViewWidget(controller: _controller),
          if (_isLoading && !_verifying)
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
          // Full-screen overlay while we confirm the payment against our server.
          if (_verifying)
            Container(
              color: Colors.white,
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: AppColors.primaryGreen),
                    SizedBox(height: 20),
                    Text('Confirming your payment…',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    SizedBox(height: 8),
                    Text('Please wait — don’t close this screen.',
                        style: TextStyle(color: AppColors.mediumGray)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
