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
/// address (buyer). The street address + coordinates are picked on the Google
/// Maps [LocationPickerScreen]; landmark is required for NG addresses.
class DeliveryAddressForm extends StatefulWidget {
  final String title;
  final List<String> labelOptions;
  // Optional prefill — pass these to edit an existing address/location in place.
  final String? initialLabel;
  final String? initialCity;
  final String? initialAddress;
  final String? initialLandmark;
  final double? initialLat;
  final double? initialLng;

  const DeliveryAddressForm({
    super.key,
    required this.title,
    required this.labelOptions,
    this.initialLabel,
    this.initialCity,
    this.initialAddress,
    this.initialLandmark,
    this.initialLat,
    this.initialLng,
  });

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

  late String _label;
  String? _city;
  final _addressController = TextEditingController();
  final _landmarkController = TextEditingController();
  double? _lat;
  double? _lng;

  // Google reverse-geocodes many NG pins to a Plus Code (e.g. "QXRW+XFG") — a
  // map code, not an address a rider can use. Detect it so we can nudge the user
  // to type a real street address.
  static final RegExp _plusCode = RegExp(
    r'\b[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\b',
    caseSensitive: false,
  );
  bool get _addressLooksLikeCode => _plusCode.hasMatch(_addressController.text.trim());

  @override
  void initState() {
    super.initState();
    _label = (widget.initialLabel != null && widget.labelOptions.contains(widget.initialLabel))
        ? widget.initialLabel!
        : widget.labelOptions.first;
    _city = (widget.initialCity != null && _cityToState.containsKey(widget.initialCity))
        ? widget.initialCity
        : null;
    _addressController.text = widget.initialAddress ?? '';
    _landmarkController.text = widget.initialLandmark ?? '';
    _lat = widget.initialLat;
    _lng = widget.initialLng;
  }

  @override
  void dispose() {
    _addressController.dispose();
    _landmarkController.dispose();
    super.dispose();
  }

  // Landmark is optional: neither courier (Shipbubble/Terminal) is sent it, so it
  // was pure friction to require. A map pin (lat/lng) IS required — the rider
  // navigates by the coordinates, so a typed address with no pin won't do.
  bool get _isValid =>
      _addressController.text.trim().isNotEmpty &&
      _city != null &&
      _lat != null &&
      _lng != null;

  Future<void> _pickOnMap() async {
    final result = await Navigator.push<LocationPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          title: 'Pick Address',
          initialAddress: _addressController.text.isEmpty ? null : _addressController.text,
          initialLat: _lat,
          initialLng: _lng,
          city: _city,
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

            // Street address — pin the exact spot on the map (captures the
            // coordinates the rider navigates to), then correct the text if the
            // auto-filled address is vague or wrong. The map often reverse-
            // geocodes to a Plus Code or an unnamed road, so the buyer/vendor
            // must be able to fix what a rider will actually read.
            TextField(
              controller: _addressController,
              onChanged: (_) => setState(() {}),
              minLines: 1,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Street Address',
                hintText: 'e.g. 12 Aba Road, Rumuola',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.home_outlined, color: AppColors.primaryGreen),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickOnMap,
                    icon: Icon(_lat == null ? Icons.map : Icons.check_circle,
                        size: 18, color: _lat == null ? AppColors.primaryGreen : AppColors.successGreen),
                    label: Text(_lat == null ? 'Pin exact spot on map' : 'Location pinned · Change'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: BorderSide(
                          color: _lat == null ? AppColors.primaryGreen : AppColors.successGreen),
                    ),
                  ),
                ),
              ],
            ),
            if (_lat == null)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Pin the exact spot so the rider is sent to the right place.',
                  style: TextStyle(fontSize: 12, color: AppColors.mediumGray),
                ),
              ),
            if (_addressLooksLikeCode)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Icon(Icons.warning_amber_rounded, color: AppColors.warningOrange, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This looks like a map code, not a street address. Please type your real address (e.g. house number, street, area) so the rider can find you.',
                        style: TextStyle(fontSize: 12, color: AppColors.warningOrange),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),

            TextField(
              controller: _landmarkController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Nearest Landmark (optional)',
                hintText: 'e.g. Near GTBank on Awolowo Road',
                helperText: 'Optional — a note to help find the exact spot',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.place, color: AppColors.primaryGreen),
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
