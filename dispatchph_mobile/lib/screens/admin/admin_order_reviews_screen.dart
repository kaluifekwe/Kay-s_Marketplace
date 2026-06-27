import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../core/services/supabase_service.dart';

/// Orders where the buyer was still silent 24h after shipment. Payout is
/// held with us for a 12h grace period (extended_release_at) so admin can
/// step in before the vendor gets paid — see auto-release-escrow edge function.
class AdminOrderReviewsScreen extends StatefulWidget {
  const AdminOrderReviewsScreen({super.key});

  @override
  State<AdminOrderReviewsScreen> createState() => _AdminOrderReviewsScreenState();
}

class _AdminOrderReviewsScreenState extends State<AdminOrderReviewsScreen> {
  List<Map<String, dynamic>> _orders = [];
  Map<String, String> _userNames = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final data = await SupabaseService.client
          .from('orders')
          .select('id, buyer_id, vendor_id, total, status, shipped_at, admin_review_flagged_at, extended_release_at, has_dispute')
          .eq('status', 'shipped')
          .eq('admin_review_flagged', true)
          .eq('has_dispute', false)
          .order('admin_review_flagged_at', ascending: true);

      final orders = List<Map<String, dynamic>>.from(data);
      final userIds = {
        ...orders.map((o) => o['buyer_id'] as String),
        ...orders.map((o) => o['vendor_id'] as String),
      }.toList();
      final names = <String, String>{};
      if (userIds.isNotEmpty) {
        final userData = await SupabaseService.client.from('users').select('id, name, email').inFilter('id', userIds);
        for (final u in (userData as List)) {
          names[u['id']] = '${u['name']} (${u['email']})';
        }
      }

      if (mounted) {
        setState(() {
          _orders = orders;
          _userNames = names;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('[AdminOrderReviews] load error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _releaseNow(Map<String, dynamic> order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Release payment now?'),
        content: const Text('This sends the held payment to the vendor immediately, skipping the rest of the 12h grace period.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Release')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await SupabaseService.client.from('orders').update({
        'status': 'auto_released',
        'payment_released': true,
      }).eq('id', order['id']).eq('status', 'shipped');

      final res = await SupabaseService.client.functions.invoke('release-escrow', body: {'order_id': order['id']});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res.status == 200 ? 'Released' : 'Release may have failed — check transactions'),
        ));
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final format = DateFormat('d MMM, h:mm a');
    return Scaffold(
      appBar: AppBar(title: const Text('Orders Needing Review')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _orders.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 200),
                        Center(child: Text('No orders awaiting review', style: TextStyle(color: AppColors.mediumGray))),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _orders.length,
                      itemBuilder: (_, i) {
                        final o = _orders[i];
                        final buyerLabel = _userNames[o['buyer_id']] ?? o['buyer_id'];
                        final vendorLabel = _userNames[o['vendor_id']] ?? o['vendor_id'];
                        final extendedReleaseAt = o['extended_release_at'] != null ? DateTime.parse(o['extended_release_at']) : null;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Buyer: $buyerLabel', style: const TextStyle(fontSize: 13)),
                                Text('Vendor: $vendorLabel', style: const TextStyle(fontSize: 13)),
                                const SizedBox(height: 6),
                                Text(
                                  '₦${(o['total'] as num).toStringAsFixed(0)}',
                                  style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.primaryGreen),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Shipped: ${o['shipped_at'] != null ? format.format(DateTime.parse(o['shipped_at'])) : 'unknown'}',
                                  style: const TextStyle(fontSize: 11, color: AppColors.mediumGray),
                                ),
                                if (extendedReleaseAt != null)
                                  Text(
                                    'Auto-releases to vendor: ${format.format(extendedReleaseAt)}',
                                    style: const TextStyle(fontSize: 11, color: AppColors.mediumGray),
                                  ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: () => _releaseNow(o),
                                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryGreen),
                                    child: const Text('Release Now', style: TextStyle(color: Colors.white)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
