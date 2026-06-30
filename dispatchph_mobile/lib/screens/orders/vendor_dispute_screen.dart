import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../chat/chat_screen.dart';
import 'vendor_return_confirm_screen.dart';

class VendorDisputeScreen extends StatefulWidget {
  final String disputeId;
  const VendorDisputeScreen({super.key, required this.disputeId});

  @override
  State<VendorDisputeScreen> createState() => _VendorDisputeScreenState();
}

class _VendorDisputeScreenState extends State<VendorDisputeScreen> {
  Dispute? _dispute;
  Order? _order;
  String _buyerName = 'Buyer';
  String _buyerPhone = '';
  Product? _replacementProduct;
  List<Product> _storeProducts = [];
  List<File> _counterEvidencePhotos = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final disputeData = await SupabaseService.client
        .from('disputes')
        .select('id, order_id, raised_by, buyer_id, vendor_id, reason, buyer_explanation, buyer_phone, delivery_address, issue_type, evidence_urls, vendor_evidence_urls, status, vendor_response, resolution_type, replacement_product_id, escalated_to_admin, resolution_deadline, buyer_submitted_at, vendor_responded_at, resolved_at, created_at, vendor_response_deadline, admin_decision, admin_notes, return_required, return_deadline, return_receipt_photos, return_verified, refund_method, video_url, vendor_confirm_deadline, vendor_return_confirmed_at, vendor_return_received_photo, is_post_payment, vendor_owes_refund')
        .eq('id', widget.disputeId)
        .maybeSingle();
    if (disputeData == null || !mounted) return;
    _dispute = Dispute.fromJson(disputeData);

    final orderData = await SupabaseService.client
        .from('orders')
        .select('id, buyer_id, vendor_id, store_id, items, total, status, shipping_method, tracking_ref, rider_name, rider_phone, delivery_method, shipping_proof_url, delivery_photo_url, payment_released, paid_at, shipped_at, delivered_at, confirmed_at, auto_release_at, created_at')
        .eq('id', _dispute!.orderId)
        .maybeSingle();
    if (orderData != null) _order = Order.fromJson(orderData);

    final buyerData = await SupabaseService.client
        .from('public_profiles')
        .select('id, name, phone')
        .eq('id', _dispute!.raisedBy)
        .maybeSingle();
    if (buyerData != null) {
      _buyerName = buyerData['name'] as String? ?? 'Buyer';
      _buyerPhone = buyerData['phone'] as String? ?? '';
    }

    if (_dispute!.replacementProductId != null) {
      final productData = await SupabaseService.client
          .from('products')
          .select('id, store_id, name, description, price, images, category, stock, created_at')
          .eq('id', _dispute!.replacementProductId!)
          .maybeSingle();
      if (productData != null) _replacementProduct = Product.fromJson(productData);
    }

    final vendorId = SupabaseService.auth.currentUser?.id ?? '';
    final storeData = await SupabaseService.client
        .from('stores')
        .select('id, vendor_id')
        .eq('vendor_id', vendorId)
        .maybeSingle();
    if (storeData != null) {
      final productsData = await SupabaseService.client
          .from('products')
          .select('id, store_id, name, description, price, images, category, stock, created_at')
          .eq('store_id', storeData['id']);
      _storeProducts = (productsData as List).map((p) => Product.fromJson(p)).toList();
    }

    if (mounted) setState(() {});
  }

  Future<void> _pickCounterEvidence() async {
    if (_counterEvidencePhotos.length >= 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum 5 photos allowed')),
      );
      return;
    }

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 80);
    if (picked != null) {
      setState(() {
        _counterEvidencePhotos.add(File(picked.path));
      });
    }
  }

  void _removePhoto(int index) {
    setState(() {
      _counterEvidencePhotos.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_dispute == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Dispute Review')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusBadge(status: _dispute!.status),

          // 24h vendor response countdown (strict flow)
          if (_dispute!.status == 'awaiting_vendor_response' && _dispute!.vendorResponseDeadline != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.errorRed.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.timer, size: 20, color: AppColors.errorRed),
                  const SizedBox(width: 8),
                  Text(
                    'Respond within: ${_dispute!.vendorTimeRemaining} or this auto-escalates to admin',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.errorRed),
                  ),
                ],
              ),
            ),
          ],

          if (_dispute!.status == 'awaiting_admin_decision') ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.escrowBlue.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
              child: const Row(children: [
                Icon(Icons.gavel, size: 20, color: AppColors.escrowBlue),
                SizedBox(width: 8),
                Expanded(child: Text('Your response has been submitted. Admin will make the final decision.', style: TextStyle(fontWeight: FontWeight.bold))),
              ]),
            ),
          ],

          if (_dispute!.status == 'vendor_confirming') ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Action Needed', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 4),
                    const Text('The buyer returned the item. Confirm or dispute receipt within 24 hours.',
                        style: TextStyle(color: AppColors.mediumGray, fontSize: 13)),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => VendorReturnConfirmScreen(disputeId: _dispute!.id)),
                      ).then((_) => _loadData()),
                      icon: const Icon(Icons.inventory_2),
                      label: const Text('Review Return'),
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryGreen, foregroundColor: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ],

          if (_dispute!.adminDecision != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (_dispute!.adminDecision == 'refund_approved' ? AppColors.errorRed : AppColors.successGreen).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _dispute!.adminDecision == 'refund_approved'
                    ? 'Admin approved the buyer\'s refund.'
                    : 'Admin denied the buyer\'s refund — no action needed.',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],

          // Legacy resolution-deadline display for older (pre-strict) disputes
          if (_dispute!.resolutionDeadline != null && _dispute!.status == 'open') ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.escrowBlue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.timer, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Time remaining: ${_dispute!.timeRemaining}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Buyer\'s Claim', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const Divider(),
                  _infoRow('Issue Type', _formatIssueType(_dispute!.issueType)),
                  _infoRow('Reason', _dispute!.reason),
                  if (_dispute!.buyerExplanation != null && _dispute!.buyerExplanation!.isNotEmpty)
                    _infoRow('Explanation', _dispute!.buyerExplanation!),
                  _infoRow('Buyer', _buyerName),
                  if (_dispute!.buyerPhone != null && _dispute!.buyerPhone!.isNotEmpty)
                    _infoRow('Buyer Phone', _dispute!.buyerPhone!),
                  if (_dispute!.deliveryAddress != null && _dispute!.deliveryAddress!.isNotEmpty)
                    _infoRow('Delivery Address', _dispute!.deliveryAddress!),
                ],
              ),
            ),
          ),

          // Buyer's evidence photos
          if (_dispute!.evidenceList.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Buyer\'s Evidence', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _dispute!.evidenceList.map((url) {
                        return GestureDetector(
                          onTap: () => _showFullImage(url),
                          child: Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.mediumGray.withOpacity(0.3)),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(url, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(Icons.image, color: AppColors.mediumGray),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // Vendor's counter-evidence
          if (_dispute!.vendorEvidenceList.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Your Evidence', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _dispute!.vendorEvidenceList.map((url) {
                        return GestureDetector(
                          onTap: () => _showFullImage(url),
                          child: Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.mediumGray.withOpacity(0.3)),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(url, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(Icons.image, color: AppColors.mediumGray),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // Replacement offered
          if (_replacementProduct != null) ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.escrowBlue.withAlpha(20),
              child: ListTile(
                leading: const Icon(Icons.swap_horiz, color: AppColors.escrowBlue),
                title: Text('Replacement: ${_replacementProduct!.name}'),
                subtitle: Text('\u20A6${NumberFormat('#,##0').format(_replacementProduct!.price)}'),
              ),
            ),
          ],

          // Vendor response
          if (_dispute!.vendorResponse != null && _dispute!.vendorResponse!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Your Response', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const Divider(),
                    Text(_dispute!.vendorResponse!),
                  ],
                ),
              ),
            ),
          ],

          // Strict-flow action: vendor submits one response with optional evidence;
          // admin makes the final refund decision (no direct accept/reject by vendor).
          if (_dispute!.status == 'awaiting_vendor_response') ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Submit Your Response', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 4),
                    const Text(
                      'Explain your side and attach evidence (e.g., pre-ship photos). Admin will review both sides and decide.',
                      style: TextStyle(color: AppColors.mediumGray, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _showUploadEvidenceSheet,
                      icon: const Icon(Icons.camera_alt),
                      label: Text('Attach Evidence (${_counterEvidencePhotos.length})'),
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.warningOrange),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: _showRespondStrictDialog,
                      icon: const Icon(Icons.send),
                      label: const Text('Submit Response to Admin'),
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryGreen, foregroundColor: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Legacy (pre-strict) actions for older disputes still in the old states
          if (['open', 'vendor_responded', 'evidence_submitted', 'replacement_offered'].contains(_dispute!.status)) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Actions', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _showRespondDialog,
                      icon: const Icon(Icons.reply),
                      label: const Text('Respond to Buyer'),
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryGreen, foregroundColor: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: _showUploadEvidenceSheet,
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Upload Counter-Evidence'),
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.warningOrange, foregroundColor: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: _showReplacementPicker,
                      icon: const Icon(Icons.swap_horiz),
                      label: const Text('Offer Replacement Product'),
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.escrowBlue, foregroundColor: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _showAcceptRefundDialog,
                            icon: const Icon(Icons.money_off),
                            label: const Text('Accept Refund'),
                            style: OutlinedButton.styleFrom(foregroundColor: AppColors.errorRed),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _showRejectRefundDialog,
                            icon: const Icon(Icons.block),
                            label: const Text('Reject'),
                            style: OutlinedButton.styleFrom(foregroundColor: AppColors.mediumGray),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
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
                            vendorName: 'Store',
                            buyerName: _buyerName,
                          ),
                        ),
                      )
                  : null,
              icon: const Icon(Icons.chat),
              label: const Text('Open Chat with Buyer'),
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.primaryGreen),
            ),
          ),
        ],
      ),
    );
  }

  String _formatIssueType(String? type) {
    switch (type) {
      case 'wrong_item': return 'Wrong item received';
      case 'damaged': return 'Item damaged in transit';
      case 'not_as_described': return 'Item not as described';
      case 'not_received': return 'Item not received';
      case 'other': return 'Other issue';
      default: return type ?? 'Not specified';
    }
  }

  void _showFullImage(String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        child: InteractiveViewer(
          child: Image.network(url, fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Center(child: Text('Could not load image')),
          ),
        ),
      ),
    );
  }

  void _showUploadEvidenceSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Upload Counter-Evidence', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              const Text('Upload photos proving your case (e.g., product before shipping, packaging photo).',
                  style: TextStyle(color: AppColors.mediumGray, fontSize: 13)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ...List.generate(_counterEvidencePhotos.length, (index) {
                    return Stack(
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(_counterEvidencePhotos[index], fit: BoxFit.cover),
                          ),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: GestureDetector(
                            onTap: () {
                              setSheetState(() => _counterEvidencePhotos.removeAt(index));
                              setState(() {});
                            },
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close, size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    );
                  }),
                  if (_counterEvidencePhotos.length < 5)
                    GestureDetector(
                      onTap: () async {
                        final picker = ImagePicker();
                        final picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 80);
                        if (picked != null) {
                          setSheetState(() => _counterEvidencePhotos.add(File(picked.path)));
                          setState(() {});
                        }
                      },
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: AppColors.lightGray,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.camera_alt, size: 24, color: AppColors.mediumGray),
                            SizedBox(height: 4),
                            Text('Add', style: TextStyle(fontSize: 12, color: AppColors.mediumGray)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _counterEvidencePhotos.isEmpty
                      ? null
                      : () async {
                          Navigator.pop(context);
                          await context.read<DisputeCubit>().vendorUploadEvidence(
                            _dispute!.id,
                            _counterEvidencePhotos.map((f) => f.path).toList(),
                          );
                          _counterEvidencePhotos.clear();
                          _loadData();
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.warningOrange,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Upload Evidence'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(color: AppColors.mediumGray)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  void _showRespondDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Respond to Buyer'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'Type your response...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await context.read<DisputeCubit>().vendorRespond(_dispute!.id, controller.text);
              _loadData();
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  void _showRespondStrictDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Submit Response'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Explain your side of the dispute...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: controller.text.trim().isEmpty
                ? null
                : () async {
                    Navigator.pop(context);
                    await context.read<DisputeCubit>().vendorRespondStrict(
                      _dispute!.id,
                      controller.text.trim(),
                      evidencePaths: _counterEvidencePhotos.map((f) => f.path).toList(),
                    );
                    _counterEvidencePhotos = [];
                    _loadData();
                  },
            child: const Text('Submit'),
          ),
        ],
      ),
    );
  }

  void _showReplacementPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Select Replacement Product', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: _storeProducts.length,
                itemBuilder: (_, i) {
                  final p = _storeProducts[i];
                  return ListTile(
                    title: Text(p.name),
                    subtitle: Text('\u20A6${NumberFormat('#,##0').format(p.price)}'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: () async {
                      Navigator.pop(context);
                      await context.read<DisputeCubit>().offerReplacement(_dispute!.id, p.id);
                      _loadData();
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAcceptRefundDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Accept Refund'),
        content: const Text('This will refund the buyer and mark the dispute as resolved. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              final success = await context.read<DisputeCubit>().acceptRefund(_dispute!.id);
              if (!mounted) return;
              if (!success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Refund failed — please try again.')),
                );
                return;
              }
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.errorRed, foregroundColor: Colors.white),
            child: const Text('Accept Refund'),
          ),
        ],
      ),
    );
  }

  void _showRejectRefundDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reject Refund'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Provide a reason for rejecting this refund request:'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 3,
              decoration: const InputDecoration(hintText: 'Reason for rejection...'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.trim().isEmpty) return;
              Navigator.pop(context);
              await context.read<DisputeCubit>().rejectRefund(_dispute!.id, controller.text);
              _loadData();
            },
            child: const Text('Reject'),
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
        text = 'Awaiting Response';
        break;
      case 'vendor_responded':
        color = AppColors.escrowBlue;
        text = 'Vendor Responded';
        break;
      case 'evidence_submitted':
        color = AppColors.warningOrange;
        text = 'Evidence Submitted';
        break;
      case 'replacement_offered':
        color = AppColors.escrowBlue;
        text = 'Replacement Offered';
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
        color = AppColors.mediumGray;
        text = 'Rejected';
        break;
      case 'escalated':
        color = AppColors.errorRed;
        text = 'Escalated to Admin';
        break;
      case 'awaiting_vendor_response':
        color = AppColors.errorRed;
        text = 'Awaiting Your Response';
        break;
      case 'awaiting_admin_decision':
        color = AppColors.escrowBlue;
        text = 'Awaiting Admin Decision';
        break;
      case 'awaiting_return':
        color = AppColors.warningOrange;
        text = 'Awaiting Buyer Return';
        break;
      case 'return_submitted':
        color = AppColors.warningOrange;
        text = 'Return Submitted';
        break;
      case 'vendor_confirming':
        color = AppColors.errorRed;
        text = 'Confirm Return Receipt';
        break;
      case 'denied':
        color = AppColors.mediumGray;
        text = 'Denied by Admin';
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
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
    );
  }
}
