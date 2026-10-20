import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../kyc/kyc_screen.dart';
import 'withdraw_screen.dart';

/// Shared wallet screen for both buyers and vendors. Vendors receive sale
/// proceeds here and withdraw to bank. Buyers see only money owed back to
/// them — a refund that had nowhere else to go — which they withdraw. Neither
/// role can load money in.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  String _userId = '';
  bool _balanceHidden = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString('auth_user_id') ?? '';
    final hidden = prefs.getBool('wallet_balance_hidden') ?? false;
    if (mounted) setState(() => _balanceHidden = hidden);
    if (_userId.isNotEmpty && mounted) {
      await context.read<WalletCubit>().load(_userId);
    }
  }

  // Privacy toggle — remembers the choice across sessions so a shoulder-surfer
  // can't see the balance if the user keeps it hidden.
  Future<void> _toggleBalanceHidden() async {
    final prefs = await SharedPreferences.getInstance();
    final next = !_balanceHidden;
    await prefs.setBool('wallet_balance_hidden', next);
    if (mounted) setState(() => _balanceHidden = next);
  }

  Future<void> _openWithdraw() async {
    // Identity must be verified before any payout leaves the platform.
    if (!await requireKyc(context, action: KycAction.withdraw)) return;
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const WithdrawScreen()),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0.00');

    return Scaffold(
      appBar: AppBar(title: const Text('Wallet')),
      body: BlocBuilder<WalletCubit, WalletState>(
        builder: (context, state) {
          if (state.isLoading) {
            return const Center(child: CircularProgressIndicator(color: AppColors.primaryGreen));
          }
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Balance card
                Card(
                  color: AppColors.primaryGreen,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text('Wallet Balance',
                                style: TextStyle(color: Colors.white70, fontSize: 14)),
                            const Spacer(),
                            InkWell(
                              onTap: _toggleBalanceHidden,
                              borderRadius: BorderRadius.circular(20),
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: Icon(
                                  _balanceHidden ? Icons.visibility_off : Icons.visibility,
                                  color: Colors.white70,
                                  size: 20,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                            _balanceHidden ? '₦ • • • • • •' : '₦${format.format(state.balance)}',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold)),
                        if (state.status == 'frozen') ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text('Frozen',
                                style: TextStyle(color: Colors.white, fontSize: 12)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Role-aware primary action
                // Withdraw only, for both roles. Buyers cannot add money: orders
                // are paid for individually at checkout, so a funded balance
                // would be money they could not spend — and holding customer
                // float is the stored-value exposure we deliberately do not take.
                // A buyer's balance here is refund money on its way out.
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _openWithdraw(),
                        icon: const Icon(Icons.account_balance),
                        label: const Text('Withdraw'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                const Text('Recent Activity',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),

                if (state.transactions.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: Text('No wallet activity yet.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.mediumGray)),
                      ),
                    ),
                  )
                else
                  ...state.transactions.map(_txTile),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _txTile(Map<String, dynamic> tx) {
    final format = NumberFormat('#,##0.00');
    final amount = (tx['amount'] as num).toDouble();
    final type = tx['type'] as String? ?? '';
    final desc = tx['description'] as String? ?? _defaultLabel(type);
    final createdAt = DateTime.parse(tx['created_at'] as String);
    final isPositive = amount > 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Text(_iconFor(type), style: const TextStyle(fontSize: 22)),
        title: Text(
          '${isPositive ? '+' : '-'}₦${format.format(amount.abs())}',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: isPositive ? AppColors.successGreen : AppColors.errorRed,
          ),
        ),
        subtitle: Text(desc, style: const TextStyle(fontSize: 13)),
        trailing: Text(
          DateFormat('MMM d').format(createdAt),
          style: const TextStyle(fontSize: 12, color: AppColors.mediumGray),
        ),
      ),
    );
  }

  String _iconFor(String type) {
    switch (type) {
      case 'fund':
        return '💰';
      case 'purchase':
        return '🛒';
      case 'escrow_release':
        return '🎉';
      case 'withdrawal':
        return '🏦';
      case 'refund':
        return '↩️';
      default:
        return '📝';
    }
  }

  String _defaultLabel(String type) {
    switch (type) {
      case 'fund':
        return 'Wallet funding';
      case 'purchase':
        return 'Order payment';
      case 'escrow_release':
        return 'Sale proceeds';
      case 'withdrawal':
        return 'Withdrawal to bank';
      case 'refund':
        return 'Refund';
      default:
        return 'Wallet activity';
    }
  }
}
