import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../chat/chat_screen.dart';
import 'refund_choice_screen.dart';

class BuyerDisputeScreen extends StatefulWidget {
  final String disputeId;
  const BuyerDisputeScreen({super.key, required this.disputeId});

  @override
  State<BuyerDisputeScreen> createState() => _BuyerDisputeScreenState();
}

class _BuyerDisputeScreenState extends State<BuyerDisputeScreen> {
  Dispute? _dispute;
  Order? _order;
  Store? _store;
  Product? _replacementProduct;
  String _vendorPhone = '';
  Timer? _refreshTimer;
  File? _packagePhoto;
  File? _handoverPhoto;
  bool _isSubmittingReturn = false;

  @override
  void initState() {
    super.initState();
    _loadData();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadData());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<File?> _takePhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 80);
    return picked != null ? File(picked.path) : null;
  }

  Future<void> _submitReturn() async {
    if (_packagePhoto == null || _handoverPhoto == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Take both photos before submitting')),
      );
      return;
    }
    setState(() => _isSubmittingReturn = true);
    final ok = await context.read<DisputeCubit>().submitReturn(
      disputeId: _dispute!.id,
      packagePhotoPath: _packagePhoto!.path,
      handoverPhotoPath: _handoverPhoto!.path,
    );
    setState(() => _isSubmittingReturn = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? 'Return submitted — admin will verify it' : 'Failed to submit return')),
      );
    }
    _loadData();
  }

  Widget _step(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 10, backgroundColor: AppColors.primaryGreen, child: Text(number, style: const TextStyle(fontSize: 11, color: Colors.white))),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _cameraButton({required bool taken, required String label, required VoidCallback onTap}) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(taken ? Icons.check_circle : Icons.camera_alt, color: taken ? AppColors.successGreen : AppColors.primaryGreen),
      label: Text(taken ? 'Photo taken ✓' : label),
      style: OutlinedButton.styleFrom(
        foregroundColor: taken ? AppColors.successGreen : AppColors.primaryGreen,
        padding: const EdgeInsets.symmetric(vertical: 12),
        minimumSize: const Size(double.infinity, 0),
      ),
    );
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    final disputeData = await SupabaseService.client
        .from('disputes')
        .select('id, order_id, raised_by, buyer_id, vendor_id, reason, status, vendor_response, replacement_product_id, resolution_type, buyer_explanation, evidence_urls, vendor_evidence_urls, vendor_response_deadline, admin_decision, admin_notes, return_required, return_deadline, return_receipt_photos, return_verified, refund_method, vendor_confirm_deadline, vendor_return_confirmed_at, created_at')
        .eq('id', widget.disputeId)
        .maybeSingle();
    if (disputeData == null || !mounted) return;
    _dispute = Dispute.fromJson(disputeData);

    final results = await Future.wait([
      SupabaseService.client
          .from('orders')
          .select('id, total, vendor_id, store_id, status')
          .eq('id', _dispute!.orderId)
          .maybeSingle(),
      if (_dispute!.replacementProductId != null)
        SupabaseService.client
            .from('products')
            .select('id, name, price, description')
            .eq('id', _dispute!.replacementProductId!)
            .maybeSingle(),
    ]);

    final orderData = results[0];
    if (orderData != null) {
      _order = Order.fromJson(orderData);
      final storeData = await SupabaseService.client
          .from('stores')
          .select('id, name, phone')
          .eq('id', _order!.storeId)
          .maybeSingle();
      if (storeData != null) {
        _store = Store.fromJson(storeData);
        _vendorPhone = _store!.phone ?? '';
      }
    }

    if (results.length > 1 && results[1] != null) {
      _replacementProduct = Product.fromJson(results[1] as Map<String, dynamic>);
    }

    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_dispute == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Dispute Details')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusBadge(status: _dispute!.status),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Order #${_dispute!.orderId.substring(0, 8)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  if (_order != null)
                    Text('Amount: \u20A6${NumberFormat('#,##0').format(_order!.total)}',
                        style: const TextStyle(fontSize: 14)),
                  const Divider(),
                  const Text('Your Issue', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_dispute!.reason, style: const TextStyle(fontSize: 14)),
                ],
              ),
            ),
          ),
          if (_store != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Vendor Information', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(children: [
                      const Icon(Icons.store, size: 20, color: AppColors.mediumGray),
                      const SizedBox(width: 8),
                      Text(_store!.name),
                    ]),
                    if (_vendorPhone.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        const Icon(Icons.phone, size: 20, color: AppColors.mediumGray),
                        const SizedBox(width: 8),
                        Text(_vendorPhone),
                        const Spacer(),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final uri = Uri.parse('tel:$_vendorPhone');
                            if (await canLaunchUrl(uri)) await launchUrl(uri);
                          },
                          icon: const Icon(Icons.call, size: 16),
                          label: const Text('Call'),
                          style: OutlinedButton.styleFrom(foregroundColor: AppColors.primaryGreen),
                        ),
                      ]),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (_dispute!.vendorResponse != null) ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.primaryGreen.withAlpha(15),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Vendor Response', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(_dispute!.vendorResponse!),
                  ],
                ),
              ),
            ),
          ],
          if (_dispute!.status == 'replacement_offered' && _replacementProduct != null) ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.escrowBlue.withAlpha(15),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Replacement Offered', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.escrowBlue)),
                    const SizedBox(height: 8),
                    Text(_replacementProduct!.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text('\u20A6${NumberFormat('#,##0').format(_replacementProduct!.price)}',
                        style: const TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 4),
                    if (_replacementProduct!.description != null)
                      Text(_replacementProduct!.description!, style: const TextStyle(color: AppColors.mediumGray)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              await context.read<DisputeCubit>().acceptReplacement(_dispute!.id);
                              _loadData();
                            },
                            icon: const Icon(Icons.check),
                            label: const Text('Accept Replacement'),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.successGreen, foregroundColor: Colors.white),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await context.read<DisputeCubit>().rejectReplacement(_dispute!.id);
                              _loadData();
                            },
                            icon: const Icon(Icons.close),
                            label: const Text('Reject'),
                            style: OutlinedButton.styleFrom(foregroundColor: AppColors.errorRed),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_dispute!.status == 'replacement_accepted') ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.successGreen.withAlpha(15),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: AppColors.successGreen),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text('Replacement accepted! The vendor will arrange delivery of the new item.',
                          style: TextStyle(color: AppColors.successGreen, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_dispute!.status == 'resolved') ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.successGreen.withAlpha(15),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.verified, color: AppColors.successGreen),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text('Dispute resolved!',
                              style: TextStyle(color: AppColors.successGreen, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('Choose how you want to receive your refund:',
                        style: TextStyle(fontSize: 13)),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => RefundChoiceScreen(
                                orderId: _dispute!.orderId,
                                amount: _order?.total ?? 0,
                                disputeId: _dispute!.id,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.account_balance_wallet),
                        label: const Text('Choose Refund Method'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryGreen,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_dispute!.status == 'rejected') ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.errorRed.withAlpha(15),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.block, color: AppColors.errorRed),
                        SizedBox(width: 12),
                        Text('Refund Rejected', style: TextStyle(color: AppColors.errorRed, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    if (_dispute!.vendorResponse != null) ...[
                      const SizedBox(height: 8),
                      Text(_dispute!.vendorResponse!),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (_dispute!.status == 'awaiting_vendor_response') ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.escrowBlue.withAlpha(15),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Row(children: [
                  Icon(Icons.timer, color: AppColors.escrowBlue),
                  SizedBox(width: 12),
                  Expanded(child: Text('Waiting for the vendor to respond within 24 hours. If they miss it, this auto-escalates to admin.')),
                ]),
              ),
            ),
          ],
          if (_dispute!.status == 'awaiting_admin_decision' || _dispute!.status == 'escalated') ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.warningOrange.withAlpha(15),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Row(children: [
                  Icon(Icons.gavel, color: AppColors.warningOrange),
                  SizedBox(width: 12),
                  Expanded(child: Text('Both sides have been heard. A platform admin is reviewing this dispute and will make the final decision.')),
                ]),
              ),
            ),
          ],
          if (_dispute!.status == 'denied') ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.errorRed.withAlpha(15),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Row(children: [
                    Icon(Icons.block, color: AppColors.errorRed),
                    SizedBox(width: 12),
                    Text('Admin Denied Your Refund', style: TextStyle(color: AppColors.errorRed, fontWeight: FontWeight.bold)),
                  ]),
                  if (_dispute!.adminNotes != null) ...[
                    const SizedBox(height: 8),
                    Text(_dispute!.adminNotes!),
                  ],
                ]),
              ),
            ),
          ],
          if (_dispute!.status == 'awaiting_return') ...[
            const SizedBox(height: 12),
            if (_dispute!.returnDeadline != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.errorRed.withAlpha(15), borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  const Icon(Icons.timer, color: AppColors.errorRed),
                  const SizedBox(width: 8),
                  Text('Return within 24 hours — by ${DateFormat('d MMM, h:mm a').format(_dispute!.returnDeadline!.toLocal())}',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.errorRed)),
                ]),
              ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: const Color(0xFFE8F5EB), borderRadius: BorderRadius.circular(12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('How to Return Item', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 8),
                  _step('1', 'Package the item securely'),
                  _step('2', 'Contact vendor to arrange pickup or drop-off'),
                  _step('3', 'Take photo of packaged item'),
                  _step('4', 'Take photo when handing item to rider/courier'),
                  _step('5', 'Submit both photos below'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_store != null)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Vendor Contact', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),
                    Row(children: [
                      const Icon(Icons.phone, color: AppColors.primaryGreen, size: 18),
                      const SizedBox(width: 8),
                      Text(_vendorPhone.isNotEmpty ? _vendorPhone : 'Contact via in-app chat',
                          style: const TextStyle(fontSize: 14, color: AppColors.primaryGreen, fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _vendorPhone.isEmpty
                              ? null
                              : () async {
                                  final uri = Uri.parse('tel:$_vendorPhone');
                                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                                },
                          icon: const Icon(Icons.call, size: 16, color: AppColors.primaryGreen),
                          label: const Text('Call', style: TextStyle(color: AppColors.primaryGreen)),
                          style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.primaryGreen)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _order != null
                              ? () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ChatScreen(
                                        orderId: _order!.id,
                                        buyerId: _dispute!.buyerId,
                                        vendorId: _order!.vendorId,
                                        vendorName: _store?.name ?? 'Vendor',
                                        buyerName: 'You',
                                      ),
                                    ),
                                  )
                              : null,
                          icon: const Icon(Icons.chat, size: 16, color: Colors.blue),
                          label: const Text('Chat', style: TextStyle(color: Colors.blue)),
                          style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.blue)),
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            const Text('Photo 1 — Packaged Item', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 4),
            Text('Take a photo of the item packaged and ready to send.', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            const SizedBox(height: 8),
            _cameraButton(
              taken: _packagePhoto != null,
              label: 'Take Package Photo',
              onTap: () async {
                final f = await _takePhoto();
                if (f != null) setState(() => _packagePhoto = f);
              },
            ),
            const SizedBox(height: 16),
            const Text('Photo 2 — Handing to Rider', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 4),
            Text('Take a photo when giving the package to the rider or courier.', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            const SizedBox(height: 8),
            _cameraButton(
              taken: _handoverPhoto != null,
              label: 'Take Handover Photo',
              onTap: () async {
                final f = await _takePhoto();
                if (f != null) setState(() => _handoverPhoto = f);
              },
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (_packagePhoto != null && _handoverPhoto != null && !_isSubmittingReturn) ? _submitReturn : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A8A2E),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  disabledBackgroundColor: Colors.grey[300],
                ),
                child: _isSubmittingReturn
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Submit Return Proof', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
          if (_dispute!.status == 'return_submitted') ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.warningOrange.withAlpha(15),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Row(children: [
                  Icon(Icons.local_shipping, color: AppColors.warningOrange),
                  SizedBox(width: 12),
                  Expanded(child: Text('Return submitted. Admin will verify the item arrived, then hand off to the vendor for final confirmation.')),
                ]),
              ),
            ),
          ],
          if (_dispute!.status == 'vendor_confirming') ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.successGreen.withAlpha(15),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Row(children: [
                    Icon(Icons.inventory_2, color: AppColors.successGreen),
                    SizedBox(width: 12),
                    Expanded(child: Text('Return verified by admin. Waiting for the vendor to confirm receipt (auto-refunds if they don\'t respond within 24 hours).')),
                  ]),
                ]),
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _order != null
                  ? () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(
                            orderId: _order!.id,
                            buyerId: _dispute!.raisedBy,
                            vendorId: _order!.vendorId,
                            vendorName: _store?.name ?? 'Vendor',
                            buyerName: 'You',
                          ),
                        ),
                      )
                  : null,
              icon: const Icon(Icons.chat),
              label: const Text('Chat with Vendor'),
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.primaryGreen),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    String text;
    switch (status) {
      case 'open':
        color = AppColors.refundOrange;
        text = 'Under Review';
        break;
      case 'vendor_responded':
        color = AppColors.escrowBlue;
        text = 'Vendor Responded';
        break;
      case 'replacement_offered':
        color = AppColors.escrowBlue;
        text = 'Replacement Offered — Decide';
        break;
      case 'replacement_accepted':
        color = AppColors.successGreen;
        text = 'Replacement Accepted';
        break;
      case 'resolved':
        color = AppColors.successGreen;
        text = 'Resolved';
        break;
      case 'rejected':
        color = AppColors.errorRed;
        text = 'Refund Rejected';
        break;
      case 'awaiting_vendor_response':
        color = AppColors.escrowBlue;
        text = 'Awaiting Vendor Response';
        break;
      case 'awaiting_admin_decision':
        color = AppColors.warningOrange;
        text = 'Admin Reviewing';
        break;
      case 'escalated':
        color = AppColors.warningOrange;
        text = 'Escalated to Admin';
        break;
      case 'awaiting_return':
        color = AppColors.successGreen;
        text = 'Refund Approved — Return Item';
        break;
      case 'return_submitted':
        color = AppColors.warningOrange;
        text = 'Return Submitted';
        break;
      case 'vendor_confirming':
        color = AppColors.successGreen;
        text = 'Vendor Confirming Receipt';
        break;
      case 'denied':
        color = AppColors.errorRed;
        text = 'Denied';
        break;
      case 'auto_closed':
        color = AppColors.mediumGray;
        text = 'Auto-Closed';
        break;
      default:
        color = AppColors.mediumGray;
        text = status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
    );
  }
}
