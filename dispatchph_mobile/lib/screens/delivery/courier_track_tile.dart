import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'order_tracking_screen.dart';

/// Tappable "Courier Booked — Track" tile shown on buyer and vendor order
/// detail screens once a Shipbubble courier has been booked for the order.
class CourierTrackTile extends StatelessWidget {
  final String deliveryId;
  const CourierTrackTile({super.key, required this.deliveryId});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => OrderTrackingScreen(deliveryId: deliveryId)),
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFE8F5EB),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primaryGreen),
        ),
        child: Row(
          children: [
            const Icon(Icons.local_shipping, color: AppColors.primaryGreen),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Courier Booked',
                      style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.primaryGreen)),
                  Text('Tap to track delivery on the map',
                      style: TextStyle(color: AppColors.mediumGray, fontSize: 12)),
                ],
              ),
            ),
            const Text('Track →', style: TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
