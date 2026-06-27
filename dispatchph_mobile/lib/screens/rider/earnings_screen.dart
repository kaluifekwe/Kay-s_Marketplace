import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class EarningsScreen extends StatelessWidget {
  const EarningsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const Text('My Earnings'),
        foregroundColor: AppColors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text(
                    'Today',
                    style: TextStyle(color: AppColors.mediumGray),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '₦10,500',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                          color: AppColors.primaryGreen,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '3 deliveries',
                    style: TextStyle(color: AppColors.mediumGray),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'This Week',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                  const SizedBox(height: 16),
                  _earningRow('Monday', '₦8,000', '2'),
                  _earningRow('Tuesday', '₦12,000', '3'),
                  _earningRow('Wednesday', '₦10,500', '3'),
                  _earningRow('Thursday', '₦0', '0'),
                  _earningRow('Friday', '₦0', '0'),
                  const Divider(),
                  _earningRow('Total', '₦30,500', '8', bold: true),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Stats',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _statItem('Rating', '4.9', Icons.star, AppColors.riderYellow),
                      _statItem('Deliveries', '47', Icons.check_circle, AppColors.successGreen),
                      _statItem('On-time', '98%', Icons.timer, AppColors.primaryGreen),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _earningRow(String day, String amount, String count, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(day, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          Text('$count deliveries',
              style: TextStyle(color: AppColors.mediumGray, fontSize: 13)),
          Text(amount,
              style: TextStyle(
                fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                color: AppColors.primaryGreen,
              )),
        ],
      ),
    );
  }

  Widget _statItem(String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label, style: TextStyle(color: AppColors.mediumGray, fontSize: 12)),
      ],
    );
  }
}
