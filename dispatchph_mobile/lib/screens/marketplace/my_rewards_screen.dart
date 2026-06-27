import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../core/services/credit_service.dart';
import '../../core/services/supabase_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MyRewardsScreen extends StatefulWidget {
  const MyRewardsScreen({super.key});

  @override
  State<MyRewardsScreen> createState() => _MyRewardsScreenState();
}

class _MyRewardsScreenState extends State<MyRewardsScreen> {
  double _balance = 0;
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final buyerId = prefs.getString('auth_user_id') ?? '';
    if (buyerId.isEmpty) return;

    final balance = await CreditService.getBalance(buyerId);
    final history = await CreditService.getHistory(buyerId);

    if (mounted) {
      setState(() {
        _balance = balance;
        _history = history;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0');
    return Scaffold(
      appBar: AppBar(title: const Text('My Rewards')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primaryGreen))
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    color: AppColors.primaryGreen,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("⚡ Kay's Credit",
                              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          Text('\u20A6${format.format(_balance)}',
                              style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          const Text('Available Balance',
                              style: TextStyle(color: Colors.white70, fontSize: 14)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text('Recent Activity',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  if (_history.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: Text('No credit activity yet.\nEarn cashback on your purchases!',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.mediumGray)),
                        ),
                      ),
                    )
                  else
                    ..._history.map((tx) {
                      final amount = (tx['amount'] as num).toDouble();
                      final type = tx['type'] as String;
                      final desc = tx['description'] as String? ?? '';
                      final createdAt = DateTime.parse(tx['created_at'] as String);
                      final isPositive = amount > 0;

                      String icon;
                      Color color;
                      switch (type) {
                        case 'cashback':
                          icon = '🎉';
                          color = AppColors.successGreen;
                          break;
                        case 'refund':
                          icon = '💰';
                          color = AppColors.escrowBlue;
                          break;
                        case 'used':
                          icon = '🛒';
                          color = AppColors.primaryGreen;
                          break;
                        default:
                          icon = '📝';
                          color = AppColors.mediumGray;
                      }

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Text(icon, style: const TextStyle(fontSize: 24)),
                          title: Text(
                            '${isPositive ? '+' : ''}\u20A6${format.format(amount.abs())}',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isPositive ? color : AppColors.errorRed),
                          ),
                          subtitle: Text(desc, style: const TextStyle(fontSize: 13)),
                          trailing: Text(
                            DateFormat('MMM d').format(createdAt),
                            style: const TextStyle(fontSize: 12, color: AppColors.mediumGray),
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}
