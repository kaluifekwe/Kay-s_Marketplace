import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../services/auth_service.dart';
import '../splash/splash_screen.dart';
import 'active_delivery_screen.dart';
import 'earnings_screen.dart';

class RiderHomeScreen extends StatefulWidget {
  const RiderHomeScreen({super.key});

  @override
  State<RiderHomeScreen> createState() => _RiderHomeScreenState();
}

class _RiderHomeScreenState extends State<RiderHomeScreen> {
  bool _isOnline = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.motorcycle, size: 24, color: AppColors.riderYellow),
            const SizedBox(width: 8),
            Text("Kay's Marketplace", style: TextStyle(color: AppColors.white)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.monetization_on_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const EarningsScreen()),
              );
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.person_outline),
            onSelected: (value) async {
              if (value == 'logout') {
                await AuthService.clearAuth();
                if (!context.mounted) return;
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const SplashScreen()),
                  (route) => false,
                );
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'logout', child: Text('Logout')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: AppColors.primaryGreen,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Chibueze O.',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            color: AppColors.white,
                          ),
                    ),
                    const Text(
                      'Verified Rider',
                      style: TextStyle(color: AppColors.riderYellow),
                    ),
                  ],
                ),
                Switch(
                  value: _isOnline,
                  activeThumbColor: AppColors.riderYellow,
                  onChanged: (val) => setState(() => _isOnline = val),
                  inactiveThumbColor: AppColors.white,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _isOnline ? AppColors.successGreen : AppColors.mediumGray,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _isOnline ? '● Online' : '○ Offline',
                    style: const TextStyle(color: AppColors.white, fontWeight: FontWeight.w600),
                  ),
                ),
                const Spacer(),
                Text(
                  'Today: 3 deliveries',
                  style: TextStyle(color: AppColors.mediumGray),
                ),
              ],
            ),
          ),
          if (!_isOnline)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.power_off, size: 64, color: AppColors.mediumGray),
                    const SizedBox(height: 16),
                    const Text(
                      'You\'re offline',
                      style: TextStyle(fontSize: 18, color: AppColors.mediumGray),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Toggle online to receive delivery requests',
                      style: TextStyle(color: AppColors.mediumGray),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  const Text(
                    'Nearby Requests',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  _RequestCard(
                    pickup: 'Rumuokoro Market',
                    dropoff: 'GRA Phase 2',
                    distance: '2.3 km',
                    fare: 3500,
                    packageType: 'Food',
                    onAccept: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ActiveDeliveryScreen()),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  _RequestCard(
                    pickup: 'Choba, UNIPORT',
                    dropoff: 'Rumuola',
                    distance: '4.1 km',
                    fare: 4000,
                    packageType: 'Document',
                    onAccept: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ActiveDeliveryScreen()),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  _RequestCard(
                    pickup: 'Mile 1 Market',
                    dropoff: 'Trans Amadi',
                    distance: '5.5 km',
                    fare: 4500,
                    packageType: 'Electronics',
                    onAccept: () {},
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  final String pickup;
  final String dropoff;
  final String distance;
  final double fare;
  final String packageType;
  final VoidCallback onAccept;

  const _RequestCard({
    required this.pickup,
    required this.dropoff,
    required this.distance,
    required this.fare,
    required this.packageType,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.riderYellow.withAlpha(40),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    packageType,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                ),
                const Spacer(),
                Text(
                  '$distance away',
                  style: TextStyle(color: AppColors.mediumGray, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.circle, color: AppColors.primaryGreen, size: 12),
                const SizedBox(width: 8),
                Text(pickup, style: const TextStyle(fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.location_on, color: AppColors.errorRed, size: 12),
                const SizedBox(width: 8),
                Text(dropoff, style: const TextStyle(fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '₦${fare.toStringAsFixed(0)}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryGreen,
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: ElevatedButton(
                    onPressed: onAccept,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      foregroundColor: AppColors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
