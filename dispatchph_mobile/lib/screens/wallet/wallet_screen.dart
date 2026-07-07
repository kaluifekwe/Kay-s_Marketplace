import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import 'add_money_screen.dart';

/// Shared wallet screen for both buyers and vendors. Buyers fund their wallet
/// and pay from it; vendors receive sale proceeds and withdraw to bank. The
/// primary action is role-aware.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  String _userId = '';
  String _role = 'buyer';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString('auth_user_id') ?? '';
    _role = prefs.getString('auth_role') ?? 'buyer';
    if (_userId.isNotEmpty && mounted) {
      await context.read<WalletCubit>().load(_userId);
    }
  }

  void _comingSoon(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what is coming soon')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0.00');
    final isVendor = _role == 'vendor';

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
                        const Text('Wallet Balance',
                            style: TextStyle(color: Colors.white70, fontSize: 14)),
                        const SizedBox(height: 8),
                        Text('₦${format.format(state.balance)}',
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
                Row(
                  children: [
                    if (!isVendor)
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const AddMoneyScreen()),
                            );
                            _load();
                          },
                          icon: const Icon(Icons.add),
                          label: const Text('Add money'),
                        ),
                      ),
                    if (isVendor)
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _comingSoon('Withdraw'),
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
