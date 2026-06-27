import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../../widgets/state_change_request_dialog.dart';

class VendorStoreSettingsScreen extends StatefulWidget {
  final Store store;
  const VendorStoreSettingsScreen({super.key, required this.store});

  @override
  State<VendorStoreSettingsScreen> createState() => _VendorStoreSettingsScreenState();
}

class _VendorStoreSettingsScreenState extends State<VendorStoreSettingsScreen> {
  late TextEditingController _descController;
  late TextEditingController _phoneController;
  late TextEditingController _whatsappController;
  late TextEditingController _bannerUrlController;
  late bool _showPhoneToBuyers;
  late String _responseTime;
  bool _isLoading = false;
  String? _vendorState;
  bool _loadingState = true;

  final _responseOptions = const {
    'usually_fast': 'Usually fast (minutes)',
    'within_hours': 'Within a few hours',
    'within_day': 'Within a day',
  };

  @override
  void initState() {
    super.initState();
    _descController = TextEditingController(text: widget.store.description ?? '');
    _phoneController = TextEditingController(text: widget.store.phone ?? '');
    _whatsappController = TextEditingController(text: widget.store.whatsappNumber ?? '');
    _bannerUrlController = TextEditingController(text: widget.store.storeBannerUrl ?? '');
    _showPhoneToBuyers = widget.store.showPhoneToBuyers;
    _responseTime = widget.store.responseTime ?? 'usually_fast';
    _loadVendorState();
  }

  Future<void> _loadVendorState() async {
    try {
      final data = await SupabaseService.client
          .from('users')
          .select('state')
          .eq('id', widget.store.vendorId)
          .maybeSingle();
      if (mounted) {
        setState(() {
          _vendorState = data?['state'] as String?;
          _loadingState = false;
        });
      }
    } catch (e) {
      print('[VendorStoreSettings] loadVendorState error: $e');
      if (mounted) setState(() => _loadingState = false);
    }
  }

  @override
  void dispose() {
    _descController.dispose();
    _phoneController.dispose();
    _whatsappController.dispose();
    _bannerUrlController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _isLoading = true);
    try {
      await SupabaseService.client.from('stores').update({
        'description': _descController.text.trim().isEmpty ? null : _descController.text.trim(),
        'phone': _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
        'whatsapp_number': _whatsappController.text.trim().isEmpty ? null : _whatsappController.text.trim(),
        'show_phone_to_buyers': _showPhoneToBuyers,
        'response_time': _responseTime,
        'store_banner_url': _bannerUrlController.text.trim().isEmpty ? null : _bannerUrlController.text.trim(),
      }).eq('id', widget.store.id);

      if (!mounted) return;
      await context.read<MarketplaceCubit>().loadProducts();
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Store Profile')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Your State', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (_loadingState)
              const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.primaryGreen.withAlpha(15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on, color: AppColors.primaryGreen, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _vendorState ?? 'Not set',
                        style: const TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (_vendorState != null)
                      TextButton(
                        onPressed: () => showStateChangeRequestDialog(
                          context,
                          userId: widget.store.vendorId,
                          currentState: _vendorState,
                        ),
                        child: const Text('Request Change'),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Text(
              'Your state is locked to keep buyer matching reliable. Changing it requires admin approval.',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
            const SizedBox(height: 24),
            const Text('Store Description', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextFormField(
              controller: _descController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Tell buyers about your store',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _bannerUrlController,
              decoration: InputDecoration(
                labelText: 'Store banner image URL (optional)',
                helperText: 'Shown at the top of your store profile',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Contact Info', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Phone Number',
                prefixIcon: const Icon(Icons.phone, color: AppColors.primaryGreen),
                helperText: 'Shown to registered buyers',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _whatsappController,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'WhatsApp Number (optional)',
                prefixIcon: const Icon(Icons.message, color: Color(0xFF25D366)),
                helperText: 'Leave blank to use phone number',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show phone to buyers'),
              subtitle: const Text('Registered buyers can see and call your number'),
              value: _showPhoneToBuyers,
              activeColor: AppColors.primaryGreen,
              onChanged: (v) => setState(() => _showPhoneToBuyers = v),
            ),
            const SizedBox(height: 16),
            const Text('Typical Response Time', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ..._responseOptions.entries.map((e) => RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.value),
                  value: e.key,
                  groupValue: _responseTime,
                  activeColor: AppColors.primaryGreen,
                  onChanged: (v) => setState(() => _responseTime = v!),
                )),
            const SizedBox(height: 24),
            PrimaryButton(
              text: 'Save Changes',
              isLoading: _isLoading,
              onPressed: _save,
              backgroundColor: AppColors.primaryGreen,
            ),
          ],
        ),
      ),
    );
  }
}
