import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../core/models/delivery_models.dart';
import '../../core/services/delivery_service.dart';
import '../../core/services/supabase_service.dart';
import 'delivery_address_form.dart';

/// Vendor-facing screen to manage the pickup locations couriers collect from.
/// At least one (the default) is required before Shipbubble can quote rates,
/// so this is surfaced from vendor settings as "📍 My Pickup Locations".
class VendorLocationsScreen extends StatefulWidget {
  final String? vendorId;
  const VendorLocationsScreen({super.key, this.vendorId});

  @override
  State<VendorLocationsScreen> createState() => _VendorLocationsScreenState();
}

class _VendorLocationsScreenState extends State<VendorLocationsScreen> {
  String _vendorId = '';
  List<VendorLocation> _locations = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    var id = widget.vendorId ?? '';
    // Live session first — see buyer_addresses_screen: a restored Supabase
    // session with a missing 'auth_user_id' pref left this empty, which showed
    // an empty list and pushed vendor_id:"" into a uuid column on save.
    if (id.isEmpty) id = SupabaseService.auth.currentUser?.id ?? '';
    final prefs = await SharedPreferences.getInstance();
    if (id.isEmpty) id = prefs.getString('auth_user_id') ?? '';
    if (id.isNotEmpty && (prefs.getString('auth_user_id') ?? '').isEmpty) {
      await prefs.setString('auth_user_id', id);
    }
    _vendorId = id;
    await _load();
  }

  Future<void> _load() async {
    if (_vendorId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final locations = await DeliveryService.getVendorLocations(_vendorId);
      if (!mounted) return;
      setState(() {
        _locations = locations;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load locations: $e', isError: true);
    }
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: isError ? AppColors.errorRed : AppColors.successGreen),
    );
  }

  Future<void> _setDefault(VendorLocation loc) async {
    if (loc.isDefault) return;
    try {
      await DeliveryService.setDefaultVendorLocation(_vendorId, loc.id);
      await _load();
    } catch (e) {
      _snack('Could not update default: $e', isError: true);
    }
  }

  Future<void> _delete(VendorLocation loc) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete location?'),
        content: Text('Remove "${loc.label}" pickup location?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: AppColors.errorRed)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await DeliveryService.deleteVendorLocation(loc.id);
      await _load();
    } catch (e) {
      _snack('Could not delete: $e', isError: true);
    }
  }

  Future<void> _addLocation() async {
    final result = await showModalBottomSheet<DeliveryAddressResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const DeliveryAddressForm(
        title: 'Add Pickup Location',
        labelOptions: ['Main Shop', 'Warehouse', 'Home', 'Other'],
      ),
    );
    if (result == null) return;
    try {
      await DeliveryService.addVendorLocation(
        vendorId: _vendorId,
        label: result.label,
        address: result.address,
        landmark: result.landmark,
        city: result.city,
        state: result.state,
        latitude: result.latitude,
        longitude: result.longitude,
        isDefault: _locations.isEmpty,
      );
      await _load();
      _snack('Pickup location saved');
    } catch (e) {
      _snack('Could not save: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Pickup Locations')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  color: const Color(0xFFE8F5EB),
                  child: const Text(
                    '📍 Add the locations where couriers should pick up your items. '
                    'Your default location is used for delivery quotes at checkout.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                Expanded(
                  child: _locations.isEmpty
                      ? _emptyState()
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _locations.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) => _locationTile(_locations[i]),
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _addLocation,
                        icon: const Icon(Icons.add_location_alt, color: Colors.white),
                        label: const Text('Add Pickup Location',
                            style: TextStyle(color: Colors.white, fontSize: 15)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryGreen,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.store_mall_directory_outlined, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text('No pickup locations yet',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey[700])),
              const SizedBox(height: 8),
              Text('Add one so couriers know where to collect orders.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            ],
          ),
        ),
      );

  Widget _locationTile(VendorLocation loc) => ListTile(
        leading: Icon(loc.isDefault ? Icons.store : Icons.location_on, color: AppColors.primaryGreen),
        title: Text(loc.label, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(loc.address, style: const TextStyle(fontSize: 12)),
            Text('📍 ${loc.landmark}', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
            Text(loc.city, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          ],
        ),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loc.isDefault)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: AppColors.primaryGreen, borderRadius: BorderRadius.circular(12)),
                child: const Text('Default', style: TextStyle(color: Colors.white, fontSize: 11)),
              ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: Colors.red[400]),
              onPressed: () => _delete(loc),
            ),
          ],
        ),
        onTap: () => _setDefault(loc),
      );
}
