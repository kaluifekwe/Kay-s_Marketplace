import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../core/models/delivery_models.dart';
import '../../core/services/delivery_service.dart';
import '../../core/services/supabase_service.dart';
import 'delivery_address_form.dart';

/// Buyer-facing delivery address book. When [selectMode] is true the screen
/// acts as a picker — tapping an address pops with that [BuyerAddress] so the
/// checkout flow can use it for courier quotes.
class BuyerAddressesScreen extends StatefulWidget {
  final String? buyerId;
  final bool selectMode;
  const BuyerAddressesScreen({super.key, this.buyerId, this.selectMode = false});

  @override
  State<BuyerAddressesScreen> createState() => _BuyerAddressesScreenState();
}

class _BuyerAddressesScreenState extends State<BuyerAddressesScreen> {
  String _buyerId = '';
  List<BuyerAddress> _addresses = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    var id = widget.buyerId ?? '';
    // The LIVE session is the source of truth, not the cached pref. Supabase
    // persists its own session, so after a restore (reinstall, cleared app data)
    // the user is signed in while 'auth_user_id' is missing — which left this
    // screen with an empty id: the list silently showed "No saved addresses"
    // and saving sent buyer_id:"" straight into a uuid column (22P02).
    if (id.isEmpty) id = SupabaseService.auth.currentUser?.id ?? '';
    final prefs = await SharedPreferences.getInstance();
    if (id.isEmpty) id = prefs.getString('auth_user_id') ?? '';
    // Heal the cache for the ~20 other screens that read this pref.
    if (id.isNotEmpty && (prefs.getString('auth_user_id') ?? '').isEmpty) {
      await prefs.setString('auth_user_id', id);
    }
    _buyerId = id;
    await _load();
  }

  Future<void> _load() async {
    if (_buyerId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final addresses = await DeliveryService.getBuyerAddresses(_buyerId);
      if (!mounted) return;
      setState(() {
        _addresses = addresses;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load addresses: $e', isError: true);
    }
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: isError ? AppColors.errorRed : AppColors.successGreen),
    );
  }

  Future<void> _addAddress() async {
    // Belt and braces: never send an empty id into a uuid column. Without this
    // the failure surfaced as a raw PostgrestException about "invalid input
    // syntax for type uuid" instead of telling the user to sign in again.
    if (_buyerId.isEmpty) {
      _snack('Could not identify your account. Please sign out and back in.', isError: true);
      return;
    }
    final result = await showModalBottomSheet<DeliveryAddressResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const DeliveryAddressForm(
        title: 'Add Delivery Address',
        labelOptions: ['Home', 'Office', 'Other'],
      ),
    );
    if (result == null) return;
    try {
      final saved = await DeliveryService.addBuyerAddress(
        buyerId: _buyerId,
        label: result.label,
        address: result.address,
        landmark: result.landmark,
        city: result.city,
        state: result.state,
        latitude: result.latitude,
        longitude: result.longitude,
        isDefault: _addresses.isEmpty,
      );
      if (widget.selectMode && mounted) {
        Navigator.pop(context, saved);
        return;
      }
      await _load();
      _snack('Address saved');
    } catch (e) {
      _snack('Could not save: $e', isError: true);
    }
  }

  Future<void> _delete(BuyerAddress addr) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete address?'),
        content: Text('Remove "${addr.label}"?'),
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
      await DeliveryService.deleteBuyerAddress(addr.id);
      await _load();
    } catch (e) {
      _snack('Could not delete: $e', isError: true);
    }
  }

  IconData _iconFor(String label) {
    switch (label) {
      case 'Home':
        return Icons.home;
      case 'Office':
        return Icons.business;
      default:
        return Icons.location_on;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.selectMode ? 'Choose Delivery Address' : 'My Delivery Addresses')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: _addresses.isEmpty
                      ? _emptyState()
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _addresses.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) => _addressTile(_addresses[i]),
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _addAddress,
                        icon: const Icon(Icons.add_location_alt, color: Colors.white),
                        label: const Text('Add New Address',
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
              Icon(Icons.location_off_outlined, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text('No saved addresses',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey[700])),
              const SizedBox(height: 8),
              Text('Add a delivery address to get courier rates at checkout.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            ],
          ),
        ),
      );

  Widget _addressTile(BuyerAddress addr) => ListTile(
        leading: Icon(_iconFor(addr.label), color: AppColors.primaryGreen),
        title: Text(addr.label, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(addr.address, style: const TextStyle(fontSize: 12)),
            Text('📍 ${addr.landmark}', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
            Text(addr.city, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          ],
        ),
        isThreeLine: true,
        trailing: widget.selectMode
            ? const Icon(Icons.chevron_right, color: AppColors.primaryGreen)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (addr.isDefault)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration:
                          BoxDecoration(color: AppColors.primaryGreen, borderRadius: BorderRadius.circular(12)),
                      child: const Text('Default', style: TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: Colors.red[400]),
                    onPressed: () => _delete(addr),
                  ),
                ],
              ),
        onTap: () async {
          if (widget.selectMode) {
            Navigator.pop(context, addr);
          } else if (!addr.isDefault) {
            await DeliveryService.setDefaultBuyerAddress(_buyerId, addr.id);
            await _load();
          }
        },
      );
}
