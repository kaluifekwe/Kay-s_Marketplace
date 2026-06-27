import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class VendorEarningsScreen extends StatelessWidget {
  const VendorEarningsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Earnings')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.monetization_on, size: 64, color: AppColors.mediumGray),
            const SizedBox(height: 16),
            const Text('No earnings yet', style: TextStyle(color: AppColors.mediumGray)),
            const SizedBox(height: 8),
            const Text('Earnings will appear here after orders are completed',
                style: TextStyle(color: AppColors.mediumGray, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
