import 'package:flutter/material.dart';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import '../../services/auth_service.dart';
import '../splash/splash_screen.dart';
import 'track_order_screen.dart';
import 'location_picker_screen.dart';

class SenderHomeScreen extends StatefulWidget {
  final String? phone;
  final String? userType;

  const SenderHomeScreen({super.key, this.phone, this.userType});

  @override
  State<SenderHomeScreen> createState() => _SenderHomeScreenState();
}

class _SenderHomeScreenState extends State<SenderHomeScreen> {
  String _pickupAddress = '';
  String _dropoffAddress = '';
  String _packageType = 'document';
  double _estimatedFare = 0;

  void _calculateFare() {
    if (_pickupAddress.isNotEmpty && _dropoffAddress.isNotEmpty) {
      final random = Random();
      setState(() {
        _estimatedFare = 2500 + (random.nextInt(3) * 1000);
      });
    }
  }

  Future<void> _pickLocation({required bool isPickup}) async {
    final result = await Navigator.push<LocationPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          title: isPickup ? 'Pickup Location' : 'Drop-off Location',
          initialAddress: isPickup ? _pickupAddress : _dropoffAddress,
        ),
      ),
    );
    if (result != null) {
      setState(() {
        if (isPickup) {
          _pickupAddress = result.address;
        } else {
          _dropoffAddress = result.address;
        }
      });
      _calculateFare();
    }
  }

  Future<void> _detectCurrentLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      final result = await Navigator.push<LocationPickerResult>(
        context,
        MaterialPageRoute(
          builder: (_) => LocationPickerScreen(
            title: 'Pickup Location',
            initialLat: pos.latitude,
            initialLng: pos.longitude,
          ),
        ),
      );
      if (result != null) {
        setState(() => _pickupAddress = result.address);
        _calculateFare();
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not detect location. Enable GPS and try again.')),
      );
    }
  }

  void _requestRider() {
    if (_pickupAddress.isEmpty || _dropoffAddress.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter pickup and drop-off addresses')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TrackOrderScreen(
          pickupAddress: _pickupAddress,
          dropoffAddress: _dropoffAddress,
          fare: _estimatedFare,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.motorcycle, size: 24, color: AppColors.riderYellow),
            const SizedBox(width: 8),
            Text("Kays Market", style: TextStyle(color: AppColors.white)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.userType == 'shop') ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.primaryGreen.withAlpha(20),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.store, color: AppColors.primaryGreen),
                    const SizedBox(width: 12),
                    Text(
                      'Your shop pickup address is saved',
                      style: TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              'Where to?',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(10),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  InkWell(
                    onTap: () => _pickLocation(isPickup: true),
                    child: Row(
                      children: [
                        const Icon(Icons.circle, color: AppColors.primaryGreen, size: 12),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Pickup',
                                style: TextStyle(color: AppColors.mediumGray, fontSize: 12),
                              ),
                              Text(
                                _pickupAddress.isNotEmpty ? _pickupAddress : 'Tap to set pickup address',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _pickupAddress.isNotEmpty ? AppColors.charcoal : AppColors.mediumGray,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_pickupAddress.isEmpty)
                          IconButton(
                            icon: const Icon(Icons.my_location, size: 20, color: AppColors.primaryGreen),
                            onPressed: _detectCurrentLocation,
                            tooltip: 'Use current location',
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 24),
                  InkWell(
                    onTap: () => _pickLocation(isPickup: false),
                    child: Row(
                      children: [
                        const Icon(Icons.location_on, color: AppColors.errorRed, size: 12),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Drop-off',
                                style: TextStyle(color: AppColors.mediumGray, fontSize: 12),
                              ),
                              Text(
                                _dropoffAddress.isNotEmpty ? _dropoffAddress : 'Tap to set drop-off address',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _dropoffAddress.isNotEmpty ? AppColors.charcoal : AppColors.mediumGray,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Package type',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ['document', 'food', 'fragile', 'electronics', 'other'].map((type) {
                  final selected = _packageType == type;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(type[0].toUpperCase() + type.substring(1)),
                      selected: selected,
                      selectedColor: AppColors.primaryGreen,
                      labelStyle: TextStyle(
                        color: selected ? AppColors.white : AppColors.charcoal,
                      ),
                      onSelected: (_) => setState(() => _packageType = type),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.riderYellow.withAlpha(80)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Estimated fare',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  Text(
                    _estimatedFare > 0 ? '₦${_estimatedFare.toStringAsFixed(0)}' : '—',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryGreen,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            PrimaryButton(
              text: 'Request a Rider',
              onPressed: _requestRider,
              backgroundColor: AppColors.primaryGreen,
            ),
          ],
        ),
      ),
    );
  }
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delivery History')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: AppColors.mediumGray),
            const SizedBox(height: 16),
            Text(
              'No deliveries yet',
              style: TextStyle(color: AppColors.mediumGray, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}