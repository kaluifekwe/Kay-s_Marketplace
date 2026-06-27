import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../sender/location_picker_screen.dart';

/// Result returned by [DeliveryAddressForm] when the user saves.
class DeliveryAddressResult {
  final String label;
  final String address;
  final String landmark;
  final String city;
  final String state;
  final double? latitude;
  final double? longitude;

  DeliveryAddressResult({
    required this.label,
    required this.address,
    required this.landmark,
    required this.city,
    required this.state,
    this.latitude,
    this.longitude,
  });
}

/// Shared bottom-sheet form for adding a pickup location (vendor) or delivery
/// address (buyer). The street address + coordinates are picked on the existing
/// OpenStreetMap [LocationPickerScreen]; landmark is required for NG addresses.
class DeliveryAddressForm extends StatefulWidget {
  final String title;
  final List<String> labelOptions;

  const DeliveryAddressForm({super.key, required this.title, required this.labelOptions});

  @override
  State<DeliveryAddressForm> createState() => _DeliveryAddressFormState();
}

class _DeliveryAddressFormState extends State<DeliveryAddressForm> {
  // Shipbubble currently covers these three cities; state is derived from city.
  static const Map<String, String> _cityToState = {
    'Lagos': 'Lagos',
    'Abuja': 'FCT (Abuja)',
    'Port Harcourt': 'Rivers',
  };

  late String _label = widget.labelOptions.first;
  String? _city;
  final _addressController = TextEditingController();
  final _landmarkController = TextEditingController();
  double? _lat;
  double? _lng;

  @override
  void dispose() {
    _addressController.dispose();
    _landmarkController.dispose();
    super.dispose();
  }

  bool get _isValid =>
      _addressController.text.trim().isNotEmpty && _landmarkController.text.trim().isNotEmpty && _city != null;

  Future<void> _pickOnMap() async {
    final result = await Navigator.push<LocationPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          title: 'Pick Address',
          initialAddress: _addressController.text.isEmpty ? null : _addressController.text,
          initialLat: _lat,
          initialLng: _lng,
        ),
      ),
    );
    if (result == null) return;
    setState(() {
      _addressController.text = result.address;
      _lat = result.lat;
      _lng = result.lng;
    });
  }

  void _save() {
    if (!_isValid) return;
    Navigator.pop(
      context,
      DeliveryAddressResult(
        label: _label,
        address: _addressController.text.trim(),
        landmark: _landmarkController.text.trim(),
        city: _city!,
        state: _cityToState[_city] ?? _city!,
        latitude: _lat,
        longitude: _lng,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),

            const Text('Type', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: widget.labelOptions.map((label) {
                final selected = _label == label;
                return GestureDetector(
                  onTap: () => setState(() => _label = label),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.primaryGreen : Colors.grey[200],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(label,
                        style: TextStyle(color: selected ? Colors.white : Colors.black87, fontSize: 12)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            DropdownButtonFormField<String>(
              initialValue: _city,
              decoration: InputDecoration(
                labelText: 'City',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.location_city, color: AppColors.primaryGreen),
              ),
              items: _cityToState.keys
                  .map((city) => DropdownMenuItem(value: city, child: Text(city)))
                  .toList(),
              onChanged: (v) => setState(() => _city = v),
            ),
            const SizedBox(height: 12),

            // Address — picked on the map so we always capture coordinates.
            InkWell(
              onTap: _pickOnMap,
              borderRadius: BorderRadius.circular(12),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Street Address',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.map, color: AppColors.primaryGreen),
                  suffixIcon: const Icon(Icons.chevron_right),
                ),
                child: Text(
                  _addressController.text.isEmpty ? 'Tap to pick on map' : _addressController.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _addressController.text.isEmpty ? AppColors.mediumGray : AppColors.charcoal,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            TextField(
              controller: _landmarkController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Nearest Landmark *',
                hintText: 'e.g. Near GTBank on Awolowo Road',
                helperText: 'Required — helps the courier find the spot',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.place, color: AppColors.warningOrange),
              ),
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isValid ? _save : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Save', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
