import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/app_image.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/storage_service.dart';
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
  late TextEditingController _addressController;
  late bool _showPhoneToBuyers;
  late String _responseTime;
  bool _isLoading = false;
  String? _vendorState;
  bool _loadingState = true;

  final _picker = ImagePicker();
  String? _logoUrl;
  String? _bannerUrl;
  bool _uploadingLogo = false;
  bool _uploadingBanner = false;

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
    _addressController = TextEditingController(text: widget.store.address ?? '');
    _logoUrl = widget.store.logoPath;
    _bannerUrl = widget.store.storeBannerUrl;
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
    _addressController.dispose();
    super.dispose();
  }

  /// Pick, compress and upload a store image (logo or banner) into the vendor's
  /// own storage folder, then keep the public URL to save with the store.
  Future<void> _pickImage({required bool isLogo}) async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
      maxWidth: 1200,
      maxHeight: 1200,
    );
    if (picked == null) return;
    setState(() {
      if (isLogo) {
        _uploadingLogo = true;
      } else {
        _uploadingBanner = true;
      }
    });
    final compressed = await StorageService.compressImage(picked);
    final url = await StorageService.uploadProductImage(
      (compressed ?? picked).path,
      widget.store.vendorId,
    );
    if (!mounted) return;
    setState(() {
      if (isLogo) {
        if (url != null) _logoUrl = url;
        _uploadingLogo = false;
      } else {
        if (url != null) _bannerUrl = url;
        _uploadingBanner = false;
      }
    });
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image upload failed, please try again')),
      );
    }
  }

  Future<void> _save() async {
    setState(() => _isLoading = true);
    try {
      await SupabaseService.client.from('stores').update({
        'description': _descController.text.trim().isEmpty ? null : _descController.text.trim(),
        'address': _addressController.text.trim().isEmpty ? null : _addressController.text.trim(),
        'phone': _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
        'whatsapp_number': _whatsappController.text.trim().isEmpty ? null : _whatsappController.text.trim(),
        'show_phone_to_buyers': _showPhoneToBuyers,
        'response_time': _responseTime,
        'logo_path': _logoUrl,
        'store_banner_url': _bannerUrl,
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
            const Text('Store Branding', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            _buildBannerPicker(),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildLogoPicker(),
                const SizedBox(width: 14),
                const Expanded(
                  child: Text(
                    'Add a logo (profile picture) and a banner. These appear on your store page and shared links.',
                    style: TextStyle(fontSize: 12, color: AppColors.mediumGray),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
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
            const Text('Store Address', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextFormField(
              controller: _addressController,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'e.g., 14 Eneka Road, Rumuokoro, Port Harcourt',
                helperText: 'Shown on your store page so buyers know where you are',
                prefixIcon: const Icon(Icons.location_on, color: AppColors.primaryGreen),
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

  Widget _buildLogoPicker() {
    return GestureDetector(
      onTap: _uploadingLogo ? null : () => _pickImage(isLogo: true),
      child: Stack(
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.lightGray,
              border: Border.all(color: AppColors.primaryGreen.withAlpha(80), width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: _uploadingLogo
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : (_logoUrl != null && _logoUrl!.isNotEmpty)
                    ? AppImage(source: _logoUrl, fit: BoxFit.cover)
                    : const Icon(Icons.storefront, color: AppColors.mediumGray, size: 32),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: const BoxDecoration(
                color: AppColors.primaryGreen,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.camera_alt, size: 14, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBannerPicker() {
    return GestureDetector(
      onTap: _uploadingBanner ? null : () => _pickImage(isLogo: false),
      child: Container(
        height: 120,
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppColors.lightGray,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primaryGreen.withAlpha(60)),
        ),
        clipBehavior: Clip.antiAlias,
        child: _uploadingBanner
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : (_bannerUrl != null && _bannerUrl!.isNotEmpty)
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      AppImage(source: _bannerUrl, fit: BoxFit.cover),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.black.withAlpha(120),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.camera_alt, size: 14, color: Colors.white),
                              SizedBox(width: 6),
                              Text('Change banner', style: TextStyle(color: Colors.white, fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                : const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_photo_alternate, size: 32, color: AppColors.primaryGreen),
                      SizedBox(height: 6),
                      Text('Add store banner', style: TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.w500)),
                    ],
                  ),
      ),
    );
  }
}
