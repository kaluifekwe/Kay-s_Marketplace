import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_image.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import 'vendor_store_screen.dart';

/// Browse all vendors (stores) across every state. Buying is still limited to
/// the buyer's own state — this is for discovery/viewing.
class AllVendorsScreen extends StatefulWidget {
  const AllVendorsScreen({super.key});

  @override
  State<AllVendorsScreen> createState() => _AllVendorsScreenState();
}

class _AllVendorsScreenState extends State<AllVendorsScreen> {
  final _searchController = TextEditingController();
  List<Store> _stores = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await SupabaseService.client
          .from('stores')
          .select('id, name, vendor_id, description, logo_path, address, phone, created_at, store_banner_url, is_verified')
          .order('created_at', ascending: false)
          .limit(200);
      final stores = (data as List).map((s) => Store.fromJson(s)).toList();
      if (mounted) {
        setState(() {
          _stores = stores;
          _loading = false;
        });
      }
    } catch (e) {
      print('[AllVendors] load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? _stores
        : _stores.where((s) => s.name.toLowerCase().contains(_query.toLowerCase())).toList();

    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: const Text('All Vendors')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search vendors by name…',
                prefixIcon: const Icon(Icons.search, color: AppColors.primaryGreen),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? const Center(
                        child: Text('No vendors found', style: TextStyle(color: AppColors.mediumGray)),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (_, i) {
                            final s = filtered[i];
                            return Card(
                              margin: EdgeInsets.zero,
                              child: ListTile(
                                leading: CircleAvatar(
                                  radius: 24,
                                  backgroundColor: AppColors.primaryGreen.withAlpha(20),
                                  child: (s.logoPath != null && s.logoPath!.isNotEmpty)
                                      ? ClipOval(
                                          child: AppImage(source: s.logoPath, width: 48, height: 48, fit: BoxFit.cover))
                                      : const Icon(Icons.storefront, color: AppColors.primaryGreen),
                                ),
                                title: Row(
                                  children: [
                                    Flexible(child: Text(s.name, overflow: TextOverflow.ellipsis)),
                                    if (s.isVerified) ...[
                                      const SizedBox(width: 4),
                                      const Icon(Icons.verified, size: 15, color: AppColors.primaryGreen),
                                    ],
                                  ],
                                ),
                                subtitle: s.description != null && s.description!.isNotEmpty
                                    ? Text(s.description!, maxLines: 1, overflow: TextOverflow.ellipsis)
                                    : null,
                                trailing: const Icon(Icons.chevron_right, color: AppColors.mediumGray),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => VendorStoreScreen(storeId: s.id)),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
