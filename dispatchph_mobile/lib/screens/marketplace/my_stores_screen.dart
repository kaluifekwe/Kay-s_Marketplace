import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_image.dart';
import '../../core/models/models.dart';
import '../../core/services/saved_stores_service.dart';
import 'vendor_store_screen.dart';

/// Buyer's saved stores. Add a store by the short numeric ID the vendor shares,
/// then tap to open the full storefront.
class MyStoresScreen extends StatefulWidget {
  const MyStoresScreen({super.key});

  @override
  State<MyStoresScreen> createState() => _MyStoresScreenState();
}

class _MyStoresScreenState extends State<MyStoresScreen> {
  List<Store> _stores = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stores = await SavedStoresService.list();
    if (mounted) {
      setState(() {
        _stores = stores;
        _loading = false;
      });
    }
  }

  Future<void> _addStoreDialog() async {
    final controller = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        Store? found;
        bool checking = false;
        String? error;
        return StatefulBuilder(
          builder: (ctx, setSt) => AlertDialog(
            title: const Text('Add a store'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "Enter the store ID the vendor shared with you.",
                  style: TextStyle(color: AppColors.mediumGray, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Store ID', hintText: 'e.g. 482910'),
                ),
                if (found != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.storefront, color: AppColors.primaryGreen, size: 18),
                      const SizedBox(width: 6),
                      Expanded(child: Text(found!.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                    ],
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: AppColors.errorRed, fontSize: 13)),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Cancel')),
              if (found == null)
                ElevatedButton(
                  onPressed: checking
                      ? null
                      : () async {
                          setSt(() {
                            checking = true;
                            error = null;
                          });
                          final s = await SavedStoresService.resolveByUniqueId(controller.text);
                          setSt(() {
                            checking = false;
                            if (s == null) {
                              error = 'No store found for that ID.';
                            } else {
                              found = s;
                            }
                          });
                        },
                  child: checking
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Find'),
                )
              else
                ElevatedButton(
                  onPressed: () async {
                    await SavedStoresService.add(found!.id);
                    if (dialogCtx.mounted) Navigator.pop(dialogCtx, true);
                  },
                  child: const Text('Add store'),
                ),
            ],
          ),
        );
      },
    );
    if (added == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Store added'), backgroundColor: AppColors.primaryGreen),
      );
      _load();
    }
  }

  Future<void> _remove(Store s) async {
    await SavedStoresService.remove(s.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const Text('My Stores'),
        actions: [
          IconButton(icon: const Icon(Icons.add), tooltip: 'Add store', onPressed: _addStoreDialog),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _stores.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.storefront_outlined, size: 56, color: AppColors.mediumGray),
                        const SizedBox(height: 12),
                        const Text(
                          'No saved stores yet.\nAsk a vendor for their store ID and add it here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.mediumGray),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _addStoreDialog,
                          icon: const Icon(Icons.add),
                          label: const Text('Add a store'),
                          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryGreen, foregroundColor: Colors.white),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _stores.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final s = _stores[i];
                      return Card(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          leading: CircleAvatar(
                            radius: 24,
                            backgroundColor: AppColors.primaryGreen.withAlpha(20),
                            child: (s.logoPath != null && s.logoPath!.isNotEmpty)
                                ? ClipOval(child: AppImage(source: s.logoPath, width: 48, height: 48, fit: BoxFit.cover))
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
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, color: AppColors.mediumGray),
                            tooltip: 'Remove',
                            onPressed: () => _remove(s),
                          ),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => VendorStoreScreen(storeId: s.id)),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
