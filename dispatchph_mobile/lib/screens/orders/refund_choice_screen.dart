import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../core/services/credit_service.dart';
import '../../core/services/payment_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RefundChoiceScreen extends StatefulWidget {
  final String orderId;
  final double amount;
  final String? disputeId;
  final String? reason;

  const RefundChoiceScreen({
    super.key,
    required this.orderId,
    required this.amount,
    this.disputeId,
    this.reason,
  });

  @override
  State<RefundChoiceScreen> createState() => _RefundChoiceScreenState();
}

class _RefundChoiceScreenState extends State<RefundChoiceScreen> {
  Map<String, dynamic>? _buyerBank;
  bool _loading = true;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _loadBankAccount();
  }

  Future<void> _loadBankAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final buyerId = prefs.getString('auth_user_id') ?? '';
    if (buyerId.isNotEmpty) {
      final bank = await CreditService.getBankAccount(buyerId);
      if (mounted) setState(() { _buyerBank = bank; _loading = false; });
    } else {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _processRefund(String method) async {
    setState(() => _processing = true);
    try {
      await CreditService.processRefund(
        orderId: widget.orderId,
        disputeId: widget.disputeId,
        reason: widget.reason,
        refundMethod: method,
      );

      if (!mounted) return;

      String message;
      switch (method) {
        case 'credit':
          message = "⚡ ${NumberFormat('#,##0').format(widget.amount)} Kay's Credit added to your account!";
          break;
        case 'bank':
          final bankName = _buyerBank?['bank_name'] ?? 'your bank';
          message = "🏦 ${NumberFormat('#,##0').format(widget.amount)} sent to $bankName. Ready in ~10 minutes.";
          break;
        default:
          message = "💳 ${NumberFormat('#,##0').format(widget.amount)} refund sent to your card. Ready in 5-7 business days.";
      }

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: AppColors.successGreen, size: 48),
          title: const Text('Refund Processed'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppColors.errorRed),
        );
        setState(() => _processing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0');
    return Scaffold(
      appBar: AppBar(title: const Text('Choose Refund Method')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primaryGreen))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: AppColors.successGreen.withAlpha(15),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Text('Refund Approved!',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text('\u20A6${format.format(widget.amount)}',
                            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: AppColors.primaryGreen)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Option 1: Kay's Credit
                _RefundOption(
                  icon: '⚡',
                  title: "Instant Kay's Credit",
                  subtitle: 'Available immediately. Use on any purchase.',
                  buttonLabel: "Get \u20A6${format.format(widget.amount)} Credit Now",
                  buttonColor: AppColors.primaryGreen,
                  enabled: !_processing,
                  onPressed: () => _processRefund('credit'),
                ),
                const SizedBox(height: 12),

                // Option 2: Bank Transfer
                _RefundOption(
                  icon: '🏦',
                  title: 'Bank Transfer',
                  subtitle: _buyerBank != null
                      ? '${_buyerBank!['bank_name']} •••• ${(_buyerBank!['account_number'] as String).substring((_buyerBank!['account_number'] as String).length - 4)}\nReady in ~10 minutes'
                      : 'Add bank account in Profile first',
                  buttonLabel: _buyerBank != null ? 'Send to My Bank' : 'No Bank Account',
                  buttonColor: AppColors.escrowBlue,
                  enabled: !_processing && _buyerBank != null,
                  onPressed: () => _processRefund('bank'),
                ),
                const SizedBox(height: 12),

                // Option 3: Card Refund
                _RefundOption(
                  icon: '💳',
                  title: 'Original Card Refund',
                  subtitle: 'Back to your card. Takes 5-7 business days.',
                  buttonLabel: 'Request Card Refund',
                  buttonColor: AppColors.warningOrange,
                  enabled: !_processing,
                  onPressed: () => _processRefund('card'),
                ),
              ],
            ),
    );
  }
}

class _RefundOption extends StatelessWidget {
  final String icon;
  final String title;
  final String subtitle;
  final String buttonLabel;
  final Color buttonColor;
  final bool enabled;
  final VoidCallback onPressed;

  const _RefundOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.buttonColor,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(icon, style: const TextStyle(fontSize: 24)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(subtitle, style: const TextStyle(color: AppColors.mediumGray, fontSize: 13)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: enabled ? onPressed : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: buttonColor,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(buttonLabel, style: const TextStyle(color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
