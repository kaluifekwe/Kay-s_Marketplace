import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/services/wallet_service.dart';
import '../../core/services/payment_service.dart';
import '../../core/services/credit_service.dart';
import '../vendor/bank_account_screen.dart';
import '../marketplace/buyer_bank_account_screen.dart';

/// Withdraw wallet balance to the user's bank. Vendors can withdraw their full
/// balance; buyers can withdraw only refunded money (the server enforces the
/// cap; we display it here).
class WithdrawScreen extends StatefulWidget {
  const WithdrawScreen({super.key});

  @override
  State<WithdrawScreen> createState() => _WithdrawScreenState();
}

class _WithdrawScreenState extends State<WithdrawScreen> {
  final _amountController = TextEditingController();
  String _userId = '';
  String _role = 'buyer';
  double _withdrawable = 0;
  Map<String, dynamic>? _bank;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString('auth_user_id') ?? '';
    _role = prefs.getString('auth_role') ?? 'buyer';
    if (_userId.isEmpty) return;
    final withdrawable = await WalletService.getWithdrawable(_userId);
    final bank = _role == 'vendor'
        ? await PaymentService.getBankAccount(_userId)
        : await CreditService.getBankAccount(_userId);
    if (!mounted) return;
    setState(() {
      _withdrawable = withdrawable;
      _bank = bank;
      _loading = false;
    });
  }

  Future<void> _addBankAccount() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _role == 'vendor' ? const BankAccountScreen() : const BuyerBankAccountScreen(),
      ),
    );
    _load();
  }

  Future<void> _submit() async {
    final amount = double.tryParse(_amountController.text.trim()) ?? 0;
    if (amount < 100) {
      setState(() => _error = 'Minimum withdrawal is ₦100');
      return;
    }
    if (amount > _withdrawable) {
      setState(() => _error = 'You can withdraw at most ₦${NumberFormat('#,##0.00').format(_withdrawable)}');
      return;
    }
    // Authorise with the 4-digit withdrawal PIN (created on first withdrawal).
    final pin = await _resolvePin();
    if (pin == null || !mounted) return;

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await WalletService.requestWithdrawal(amount: amount, pin: pin);
      if (!mounted) return;
      await context.read<WalletCubit>().load(_userId);
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: AppColors.successGreen, size: 56),
          title: const Text('Withdrawal on the way'),
          content: Text(
            '₦${NumberFormat('#,##0.00').format(amount)} is being sent to your bank. '
            'It usually arrives within minutes.',
          ),
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
    } on WalletNoBankAccount {
      if (!mounted) return;
      setState(() => _submitting = false);
      _addBankAccount();
    } on WalletPinError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _submitting = false;
      });
    }
  }

  /// Returns the PIN to authorise the withdrawal, creating it on first use.
  /// Returns null if the user cancels or something goes wrong (message set).
  Future<String?> _resolvePin() async {
    ({bool hasPin, bool locked}) status;
    try {
      status = await WalletService.getWithdrawalPinStatus();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not check your withdrawal PIN. Try again.');
      return null;
    }
    if (!mounted) return null;
    if (status.locked) {
      setState(() => _error = 'Withdrawals are locked after too many wrong PIN attempts. Try again later.');
      return null;
    }
    return status.hasPin ? _enterPinFlow() : _createPinFlow();
  }

  /// First-time setup: enter a PIN, confirm it, then save it.
  Future<String?> _createPinFlow() async {
    final pin1 = await _promptPin(
      title: 'Create withdrawal PIN',
      subtitle: "Set a 4-digit PIN. You'll enter it every time you withdraw.",
    );
    if (pin1 == null || !mounted) return null;
    final pin2 = await _promptPin(title: 'Confirm PIN', subtitle: 'Enter your PIN again to confirm.');
    if (pin2 == null || !mounted) return null;
    if (pin1 != pin2) {
      setState(() => _error = "PINs didn't match. Please try again.");
      return null;
    }
    try {
      await WalletService.setWithdrawalPin(pin1);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      return null;
    }
    return pin1;
  }

  Future<String?> _enterPinFlow() => _promptPin(
        title: 'Enter withdrawal PIN',
        subtitle: 'Enter your 4-digit PIN to authorise this withdrawal.',
      );

  /// A 4-digit PIN entry dialog. Returns the digits, or null if cancelled.
  Future<String?> _promptPin({required String title, required String subtitle}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(subtitle, style: const TextStyle(color: AppColors.mediumGray, fontSize: 13)),
            ),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 4,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 12),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(counterText: '', hintText: '••••'),
              onSubmitted: (v) {
                if (v.trim().length == 4) Navigator.pop(ctx, v.trim());
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (controller.text.trim().length == 4) Navigator.pop(ctx, controller.text.trim());
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.00');
    return Scaffold(
      appBar: AppBar(title: const Text('Withdraw')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primaryGreen))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: AppColors.primaryGreen,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _role == 'vendor' ? 'Available to withdraw' : 'Withdrawable (refunds only)',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const SizedBox(height: 6),
                        Text('₦${fmt.format(_withdrawable)}',
                            style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Destination bank
                if (_bank == null)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.account_balance, color: AppColors.primaryGreen),
                      title: const Text('Add a bank account'),
                      subtitle: const Text('Needed to receive your withdrawal'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _addBankAccount,
                    ),
                  )
                else
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.account_balance, color: AppColors.primaryGreen),
                      title: Text('${_bank!['bank_name'] ?? ''} • ${_bank!['account_number'] ?? ''}'),
                      subtitle: Text(_bank!['account_name'] as String? ?? ''),
                      trailing: TextButton(onPressed: _addBankAccount, child: const Text('Change')),
                    ),
                  ),
                const SizedBox(height: 16),

                TextField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  decoration: const InputDecoration(
                    labelText: 'Amount (₦)',
                    border: OutlineInputBorder(),
                    prefixText: '₦ ',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: const TextStyle(color: AppColors.errorRed, fontSize: 13)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: (_submitting || _bank == null || _withdrawable < 100) ? null : _submit,
                  child: _submitting
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Withdraw to bank'),
                ),
                if (_role != 'vendor') ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Buyers can only withdraw money that was refunded to the wallet.',
                    style: TextStyle(color: AppColors.mediumGray, fontSize: 12),
                  ),
                ],
              ],
            ),
    );
  }
}
