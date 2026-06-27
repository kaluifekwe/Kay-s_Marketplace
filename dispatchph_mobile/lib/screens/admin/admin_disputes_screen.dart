import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';

class AdminDisputesScreen extends StatefulWidget {
  const AdminDisputesScreen({super.key});

  @override
  State<AdminDisputesScreen> createState() => _AdminDisputesScreenState();
}

class _AdminDisputesScreenState extends State<AdminDisputesScreen> {
  List<Dispute> _disputes = [];
  Map<String, String> _buyerNames = {};
  Map<String, String> _vendorNames = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final disputes = await context.read<DisputeCubit>().loadDisputesForAdmin();
    final userIds = {...disputes.map((d) => d.buyerId), ...disputes.map((d) => d.vendorId)}.where((id) => id.isNotEmpty).toList();
    final names = <String, String>{};
    if (userIds.isNotEmpty) {
      final userData = await SupabaseService.client.from('users').select('id, name, email').inFilter('id', userIds);
      for (final u in (userData as List)) {
        names[u['id']] = '${u['name']} (${u['email']})';
      }
    }
    if (mounted) {
      setState(() {
        _disputes = disputes;
        _buyerNames = names;
        _vendorNames = names;
        _isLoading = false;
      });
    }
  }

  Future<void> _approve(Dispute d, {required bool requireReturn}) async {
    final adminId = SupabaseService.auth.currentUser?.id ?? '';
    final notes = await _promptNotes('Approve Refund', 'Admin notes (optional)');
    final ok = await context.read<DisputeCubit>().adminApproveRefund(
      disputeId: d.id,
      adminId: adminId,
      notes: notes,
      requireReturn: requireReturn,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Approved' : 'Failed')));
    }
    _load();
  }

  Future<void> _deny(Dispute d) async {
    final adminId = SupabaseService.auth.currentUser?.id ?? '';
    final notes = await _promptNotes('Deny Refund', 'Reason for denial (required)');
    if (notes == null || notes.trim().isEmpty) return;
    final ok = await context.read<DisputeCubit>().adminDenyRefund(disputeId: d.id, adminId: adminId, notes: notes);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Denied — buyer received a strike' : 'Failed')));
    }
    _load();
  }

  Future<void> _verifyReturn(Dispute d) async {
    final adminId = SupabaseService.auth.currentUser?.id ?? '';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Verify Return'),
        content: const Text('Confirm the returned item has physically arrived before processing the refund.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Verified — Refund')),
        ],
      ),
    );
    if (confirm != true) return;
    final ok = await context.read<DisputeCubit>().adminVerifyReturn(disputeId: d.id, adminId: adminId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Refund processed' : 'Failed')));
    }
    _load();
  }

  Future<String?> _promptNotes(String title, String hint) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, maxLines: 3, decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Confirm')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Disputes — Admin Review')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _disputes.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 200),
                      Center(child: Text('No disputes need review', style: TextStyle(color: AppColors.mediumGray))),
                    ])
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _disputes.length,
                      itemBuilder: (_, i) {
                        final d = _disputes[i];
                        final isReturnReview = d.status == 'return_submitted';
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Order #${d.orderId.substring(0, 8)}',
                                    style: const TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(height: 6),
                                Text('Buyer: ${_buyerNames[d.buyerId] ?? d.buyerId}', style: const TextStyle(fontSize: 13)),
                                Text('Vendor: ${_vendorNames[d.vendorId] ?? d.vendorId}', style: const TextStyle(fontSize: 13)),
                                const SizedBox(height: 6),
                                Text('Issue: ${d.issueType ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w600)),
                                Text(d.buyerExplanation ?? d.reason, style: const TextStyle(fontSize: 13)),
                                if (d.evidenceList.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  const Text('Buyer evidence:', style: TextStyle(fontSize: 12, color: AppColors.mediumGray)),
                                  _photoRow(d.evidenceList),
                                ],
                                if (d.vendorResponse != null) ...[
                                  const SizedBox(height: 8),
                                  Text('Vendor response: ${d.vendorResponse}', style: const TextStyle(fontSize: 13)),
                                ],
                                if (d.vendorEvidenceList.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  const Text('Vendor evidence:', style: TextStyle(fontSize: 12, color: AppColors.mediumGray)),
                                  _photoRow(d.vendorEvidenceList),
                                ],
                                if (isReturnReview && d.returnReceiptPhotosList.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  const Text('Buyer return photos (package + handover):', style: TextStyle(fontSize: 12, color: AppColors.mediumGray)),
                                  _photoRow(d.returnReceiptPhotosList),
                                ],
                                const SizedBox(height: 4),
                                Text(DateFormat('d MMM, h:mm a').format(d.createdAt.toLocal()),
                                    style: const TextStyle(fontSize: 11, color: AppColors.mediumGray)),
                                const SizedBox(height: 12),
                                if (isReturnReview)
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      onPressed: () => _verifyReturn(d),
                                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryGreen, foregroundColor: Colors.white),
                                      child: const Text('Verify Return & Refund'),
                                    ),
                                  )
                                else
                                  Column(
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: OutlinedButton(
                                              onPressed: () => _deny(d),
                                              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
                                              child: const Text('Deny', style: TextStyle(color: Colors.red)),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: ElevatedButton(
                                              onPressed: () => _approve(d, requireReturn: true),
                                              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryGreen),
                                              child: const Text('Approve (w/ Return)', style: TextStyle(color: Colors.white, fontSize: 12)),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      SizedBox(
                                        width: double.infinity,
                                        child: TextButton(
                                          onPressed: () => _approve(d, requireReturn: false),
                                          child: const Text('Approve — No Return Needed (e.g. not_received)'),
                                        ),
                                      ),
                                    ],
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

  Widget _photoRow(List<String> urls) {
    return SizedBox(
      height: 70,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: urls.map((url) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(url, width: 70, height: 70, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(Icons.image, color: AppColors.mediumGray)),
          ),
        )).toList(),
      ),
    );
  }
}
