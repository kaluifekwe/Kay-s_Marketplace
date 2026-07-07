import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/services/wallet_service.dart';

/// Buyer funding screen. If the buyer has no virtual account yet, collect their
/// BVN (required by Flutterwave for a permanent NGN account) and generate one.
/// Once it exists, show the fixed account number to transfer into — funds land
/// in the wallet automatically via the flutterwave-webhook.
class AddMoneyScreen extends StatefulWidget {
  const AddMoneyScreen({super.key});

  @override
  State<AddMoneyScreen> createState() => _AddMoneyScreenState();
}

class _AddMoneyScreenState extends State<AddMoneyScreen> {
  final _bvnController = TextEditingController();
  String _userId = '';
  String? _accountNumber;
  String? _bankName;
  bool _loading = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _bvnController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString('auth_user_id') ?? '';
    final wallet = await WalletService.getWallet(_userId);
    if (!mounted) return;
    setState(() {
      _accountNumber = wallet?['flw_va_number'] as String?;
      _bankName = wallet?['flw_va_bank'] as String?;
      _loading = false;
    });
  }

  Future<void> _generate() async {
    final bvn = _bvnController.text.trim();
    if (!RegExp(r'^\d{11}$').hasMatch(bvn)) {
      setState(() => _error = 'Enter a valid 11-digit BVN');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final result = await WalletService.createVirtualAccount(bvn: bvn);
      if (!mounted) return;
      setState(() {
        _accountNumber = result['account_number'] as String?;
        _bankName = result['bank_name'] as String?;
        _creating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _creating = false;
      });
    }
  }

  Future<void> _refreshBalance() async {
    if (_userId.isNotEmpty) {
      await context.read<WalletCubit>().load(_userId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Balance refreshed')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Money')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primaryGreen))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: _accountNumber == null ? _buildBvnForm() : _buildAccountDetails(),
            ),
    );
  }

  Widget _buildBvnForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Create your funding account',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          'We\'ll generate a dedicated bank account for topping up your wallet. '
          'Your BVN is required by our payment partner to open it and is never stored.',
          style: TextStyle(color: AppColors.mediumGray, fontSize: 13),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _bvnController,
          keyboardType: TextInputType.number,
          maxLength: 11,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'BVN',
            hintText: '11-digit Bank Verification Number',
            border: OutlineInputBorder(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: AppColors.errorRed, fontSize: 13)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _creating ? null : _generate,
          child: _creating
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Generate account'),
        ),
      ],
    );
  }

  Widget _buildAccountDetails() {
    return ListView(
      children: [
        Card(
          color: AppColors.primaryGreen,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Transfer to this account',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_accountNumber ?? '',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                    IconButton(
                      icon: const Icon(Icons.copy, color: Colors.white),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _accountNumber ?? ''));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Account number copied')),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(_bankName ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How it works', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Text(
                  '1. Transfer any amount to the account above from your bank app.\n'
                  '2. Your wallet is credited automatically within a few minutes.\n'
                  '3. Use your wallet balance to pay for orders.',
                  style: TextStyle(color: AppColors.mediumGray, fontSize: 13, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _refreshBalance,
          icon: const Icon(Icons.refresh),
          label: const Text('I\'ve sent it — refresh balance'),
        ),
      ],
    );
  }
}
