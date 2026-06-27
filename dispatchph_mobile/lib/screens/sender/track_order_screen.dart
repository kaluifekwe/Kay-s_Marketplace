import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';

class TrackOrderScreen extends StatefulWidget {
  final String pickupAddress;
  final String dropoffAddress;
  final double fare;

  const TrackOrderScreen({
    super.key,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.fare,
  });

  @override
  State<TrackOrderScreen> createState() => _TrackOrderScreenState();
}

class _TrackOrderScreenState extends State<TrackOrderScreen> {
  String _status = 'pending';
  String _riderName = '';

  @override
  void initState() {
    super.initState();
    _simulateRiderAccept();
  }

  void _simulateRiderAccept() async {
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    setState(() {
      _status = 'accepted';
      _riderName = 'Chibueze O.';
    });

    await Future.delayed(const Duration(seconds: 5));
    if (!mounted) return;
    setState(() => _status = 'picked_up');

    await Future.delayed(const Duration(seconds: 8));
    if (!mounted) return;
    setState(() => _status = 'delivered');
  }

  IconData _getStatusIcon() {
    switch (_status) {
      case 'accepted': return Icons.motorcycle;
      case 'picked_up': return Icons.inventory_2;
      case 'delivered': return Icons.check_circle;
      default: return Icons.hourglass_empty;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const Text('Delivery in Progress'),
        actions: [
          IconButton(
            icon: const Icon(Icons.phone),
            onPressed: _riderName.isNotEmpty ? () {} : null,
          ),
          IconButton(
            icon: const Icon(Icons.chat),
            onPressed: _riderName.isNotEmpty ? () {} : null,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            height: 250,
            color: AppColors.mediumGray.withAlpha(40),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.map, size: 48, color: AppColors.mediumGray),
                  const SizedBox(height: 8),
                  Text('Map view', style: TextStyle(color: AppColors.mediumGray)),
                  if (_riderName.isNotEmpty)
                    Text(
                      'Rider is ${_status == 'picked_up' ? "heading to drop-off" : "coming to you"}',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_riderName.isNotEmpty) ...[
                    Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppColors.primaryGreen,
                          child: Text(
                            _riderName[0],
                            style: const TextStyle(color: AppColors.white),
                          ),
                        ),
                        title: Text(_riderName),
                        subtitle: Text(_getStatusText()),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star, color: AppColors.riderYellow, size: 20),
                            const Text('4.9'),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _StatusTile(
                    icon: _getStatusIcon(),
                    label: _getStatusText(),
                    isActive: true,
                  ),
                  const SizedBox(height: 8),
                  _LocationRow(
                    icon: Icons.circle,
                    color: AppColors.primaryGreen,
                    address: widget.pickupAddress,
                    label: 'Pickup',
                  ),
                  const SizedBox(height: 8),
                  _LocationRow(
                    icon: Icons.location_on,
                    color: AppColors.errorRed,
                    address: widget.dropoffAddress,
                    label: 'Drop-off',
                  ),
                  const Spacer(),
                  if (_status == 'delivered') ...[
                    PrimaryButton(
                      text: 'Rate Delivery',
                      backgroundColor: AppColors.primaryGreen,
                      onPressed: () {
                        Navigator.pop(context);
                      },
                    ),
                  ] else ...[
                    Center(
                      child: Text(
                        'Fare: ₦${widget.fare.toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryGreen,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getStatusText() {
    switch (_status) {
      case 'pending': return 'Looking for a nearby rider...';
      case 'accepted': return 'Rider is coming to pick up';
      case 'picked_up': return 'Package picked up, heading to destination';
      case 'delivered': return 'Package delivered successfully!';
      default: return _status;
    }
  }
}

class _StatusTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;

  const _StatusTile({
    required this.icon,
    required this.label,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: isActive ? AppColors.primaryGreen : AppColors.mediumGray),
        title: Text(label),
      ),
    );
  }
}

class _LocationRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String address;
  final String label;

  const _LocationRow({
    required this.icon,
    required this.color,
    required this.address,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Icon(icon, color: color, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: AppColors.mediumGray, fontSize: 12)),
              Text(address, style: const TextStyle(fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ],
    );
  }
}
