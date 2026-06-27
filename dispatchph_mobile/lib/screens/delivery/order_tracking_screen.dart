import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme/app_theme.dart';
import '../../core/models/delivery_models.dart';
import '../../core/services/delivery_service.dart';

/// Live delivery tracking on an OpenStreetMap map. Shows the pickup and
/// delivery pins, a road route (OSRM), and a courier marker whose position is
/// simulated from the current delivery status. Status is polled periodically
/// because Shipbubble drives it via the shipbubble-webhook.
class OrderTrackingScreen extends StatefulWidget {
  final String deliveryId;
  const OrderTrackingScreen({super.key, required this.deliveryId});

  @override
  State<OrderTrackingScreen> createState() => _OrderTrackingScreenState();
}

class _OrderTrackingScreenState extends State<OrderTrackingScreen> {
  final MapController _mapController = MapController();
  Delivery? _delivery;
  List<LatLng> _route = [];
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _loadInitial();
    // Shipbubble pushes status via webhook; poll so the map stays current.
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    try {
      final delivery = await DeliveryService.getDelivery(widget.deliveryId);
      if (delivery == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'Delivery not found';
          });
        }
        return;
      }
      final route = await DeliveryService.getRoute(
        fromLat: delivery.pickupLatitude,
        fromLng: delivery.pickupLongitude,
        toLat: delivery.deliveryLatitude,
        toLng: delivery.deliveryLongitude,
      );
      if (!mounted) return;
      setState(() {
        _delivery = delivery;
        _route = route;
        _loading = false;
      });
      _fitMap();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _refreshStatus() async {
    final updated = await DeliveryService.getDelivery(widget.deliveryId);
    if (updated == null || !mounted) return;
    setState(() => _delivery = updated);
  }

  void _fitMap() {
    final d = _delivery;
    if (d == null || !d.hasPickupCoords || !d.hasDeliveryCoords) return;
    final points = [
      LatLng(d.pickupLatitude!, d.pickupLongitude!),
      LatLng(d.deliveryLatitude!, d.deliveryLongitude!),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _mapController.fitCamera(
          CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(60)),
        );
      } catch (_) {}
    });
  }

  Future<void> _callCourier(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Track Delivery')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.errorRed)))
              : Column(
                  children: [
                    Expanded(flex: 1, child: _map()),
                    Expanded(flex: 1, child: _statusPanel()),
                  ],
                ),
    );
  }

  Widget _map() {
    final d = _delivery!;
    final markers = <Marker>[];
    if (d.hasPickupCoords) {
      markers.add(Marker(
        point: LatLng(d.pickupLatitude!, d.pickupLongitude!),
        width: 40,
        height: 40,
        child: const Icon(Icons.store, color: AppColors.primaryGreen, size: 36),
      ));
    }
    if (d.hasDeliveryCoords) {
      markers.add(Marker(
        point: LatLng(d.deliveryLatitude!, d.deliveryLongitude!),
        width: 40,
        height: 40,
        child: const Icon(Icons.location_on, color: AppColors.errorRed, size: 36),
      ));
    }
    if (_route.isNotEmpty) {
      markers.add(Marker(
        point: DeliveryService.riderPosition(_route, d.status),
        width: 44,
        height: 44,
        child: Container(
          decoration: const BoxDecoration(color: AppColors.primaryBlue, shape: BoxShape.circle),
          padding: const EdgeInsets.all(6),
          child: const Icon(Icons.delivery_dining, color: Colors.white, size: 24),
        ),
      ));
    }

    final center = _route.isNotEmpty
        ? _route[(_route.length / 2).floor()]
        : (d.hasPickupCoords ? LatLng(d.pickupLatitude!, d.pickupLongitude!) : const LatLng(6.5244, 3.3792));

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(initialCenter: center, initialZoom: 12),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.dispatchph.mobile',
        ),
        if (_route.length >= 2)
          PolylineLayer(
            polylines: [Polyline(points: _route, color: AppColors.primaryGreen, strokeWidth: 4)],
          ),
        MarkerLayer(markers: markers),
      ],
    );
  }

  Widget _statusPanel() {
    final d = _delivery!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (d.courierName != null) ...[
            Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFFE8F5EB),
                  child: Icon(Icons.delivery_dining, color: AppColors.primaryGreen),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.courierName!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      const Text('Your courier', style: TextStyle(color: AppColors.mediumGray, fontSize: 12)),
                    ],
                  ),
                ),
                if (d.courierPhone != null && d.courierPhone!.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.phone, color: AppColors.primaryGreen),
                    onPressed: () => _callCourier(d.courierPhone!),
                  ),
              ],
            ),
            const Divider(height: 20),
          ],
          if (d.status == 'failed' || d.status == 'cancelled')
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red[200]!),
              ),
              child: Text(
                d.status == 'failed'
                    ? '⚠️ Delivery failed. Please contact support.'
                    : 'This delivery was cancelled.',
                style: TextStyle(color: Colors.red[800], fontSize: 13),
              ),
            ),
          const Text('Delivery Status', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 12),
          ..._timelineSteps(d.status),
          if (d.estimatedDelivery != null && d.estimatedDelivery!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.schedule, size: 16, color: AppColors.mediumGray),
                const SizedBox(width: 6),
                Text('Estimated: ${d.estimatedDelivery}',
                    style: const TextStyle(fontSize: 12, color: AppColors.mediumGray)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _timelineSteps(String currentStatus) {
    const labels = {
      'pending': 'Courier Booked',
      'confirmed': 'Confirmed',
      'picked_up': 'Picked Up',
      'in_transit': 'In Transit',
      'delivered': 'Delivered',
    };
    final steps = DeliveryService.statusSteps;
    // failed/cancelled aren't on the happy-path ladder; show progress up to
    // wherever the delivery got before it stopped.
    final currentIndex = steps.indexOf(currentStatus);
    return List.generate(steps.length, (i) {
      final step = steps[i];
      final isDone = currentIndex >= i && currentIndex != -1;
      final isCurrent = currentIndex == i;
      final isLast = i == steps.length - 1;
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDone ? AppColors.primaryGreen : Colors.grey[300],
                  ),
                  child: Icon(isDone ? Icons.check : Icons.circle, color: Colors.white, size: 14),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(width: 2, color: isDone ? AppColors.primaryGreen : Colors.grey[300]),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(bottom: 16, top: 2),
              child: Text(
                labels[step] ?? step,
                style: TextStyle(
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  color: isCurrent
                      ? AppColors.primaryGreen
                      : isDone
                          ? AppColors.charcoal
                          : AppColors.mediumGray,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
