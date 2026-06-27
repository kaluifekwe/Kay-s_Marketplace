import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';

class VendorReturnConfirmScreen extends StatefulWidget {
  final String disputeId;
  const VendorReturnConfirmScreen({super.key, required this.disputeId});

  @override
  State<VendorReturnConfirmScreen> createState() => _VendorReturnConfirmScreenState();
}

class _VendorReturnConfirmScreenState extends State<VendorReturnConfirmScreen> {
  Dispute? _dispute;
  File? _receivedPhoto;
  File? _notReceivedPhoto;
  bool _isSubmitting = false;
  Timer? _tickTimer;

  static const _disputeFields = 'id, order_id, raised_by, buyer_id, vendor_id, reason, status, return_receipt_photos, vendor_confirm_deadline, created_at';

  @override
  void initState() {
    super.initState();
    _load();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final data = await SupabaseService.client
        .from('disputes')
        .select(_disputeFields)
        .eq('id', widget.disputeId)
        .maybeSingle();
    if (data != null && mounted) {
      setState(() => _dispute = Dispute.fromJson(data));
    }
  }

  Future<File?> _takePhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 80);
    return picked != null ? File(picked.path) : null;
  }

  Future<void> _confirmReceived() async {
    if (_receivedPhoto == null) return;
    setState(() => _isSubmitting = true);
    final ok = await context.read<DisputeCubit>().vendorConfirmReturnReceived(
      disputeId: widget.disputeId,
      receivedPhotoPath: _receivedPhoto!.path,
    );
    setState(() => _isSubmitting = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? 'Confirmed — refund processed for buyer' : 'Failed to confirm')),
      );
      if (ok) Navigator.pop(context);
    }
  }

  void _showNotReceivedSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Upload Evidence', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 8),
              Text('Take a photo showing you did not receive the item.', style: TextStyle(color: Colors.grey[600])),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final f = await _takePhoto();
                  if (f != null) setSheetState(() => _notReceivedPhoto = f);
                },
                icon: const Icon(Icons.camera_alt),
                label: Text(_notReceivedPhoto == null ? 'Take Photo' : 'Photo taken ✓'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _notReceivedPhoto == null
                      ? null
                      : () async {
                          Navigator.pop(ctx);
                          setState(() => _isSubmitting = true);
                          final ok = await context.read<DisputeCubit>().vendorDisputeReturn(
                            disputeId: widget.disputeId,
                            notReceivedPhotoPath: _notReceivedPhoto!.path,
                          );
                          setState(() => _isSubmitting = false);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(ok ? 'Sent to admin for final review' : 'Failed to submit')),
                            );
                            if (ok) Navigator.pop(context);
                          }
                        },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red[700]),
                  child: const Text('Submit', style: TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_dispute == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final deadline = _dispute!.vendorConfirmDeadline;
    final remaining = deadline?.difference(DateTime.now());
    final hours = remaining?.inHours ?? 0;
    final mins = (remaining?.inMinutes ?? 0).remainder(60);
    final expired = remaining != null && remaining.isNegative;

    return Scaffold(
      appBar: AppBar(title: const Text('Return Confirmation')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFFE8F5EB), borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              const Icon(Icons.inventory_2, color: Color(0xFF1A8A2E), size: 36),
              const SizedBox(height: 8),
              const Text('Return Item Confirmation', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              const Text('The buyer claims to have returned the item.',
                  style: TextStyle(color: Colors.grey, fontSize: 13), textAlign: TextAlign.center),
            ]),
          ),
          const SizedBox(height: 16),
          if (deadline != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (expired || hours < 4) ? Colors.red[50] : Colors.orange[50],
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: (expired || hours < 4) ? Colors.red[300]! : Colors.orange[300]!),
              ),
              child: Row(children: [
                Icon(Icons.timer, color: (expired || hours < 4) ? Colors.red[700] : Colors.orange[700]),
                const SizedBox(width: 8),
                Text(
                  expired ? 'Deadline passed — refund may auto-process any moment' : 'Auto-refunds to buyer in: ${hours}h ${mins}m',
                  style: TextStyle(color: (expired || hours < 4) ? Colors.red[800] : Colors.orange[800], fontWeight: FontWeight.w600),
                ),
              ]),
            ),
          const SizedBox(height: 20),
          const Text('Buyer Return Evidence', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 8, mainAxisSpacing: 8),
            itemCount: _dispute!.returnReceiptPhotosList.length,
            itemBuilder: (_, i) => ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(_dispute!.returnReceiptPhotosList[i], fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(Icons.image, color: AppColors.mediumGray)),
            ),
          ),
          const SizedBox(height: 20),
          const Text('Take a photo of the return', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          Text('Take a photo of the returned item you received.', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _isSubmitting
                ? null
                : () async {
                    final f = await _takePhoto();
                    if (f != null) setState(() => _receivedPhoto = f);
                  },
            icon: Icon(_receivedPhoto != null ? Icons.check_circle : Icons.camera_alt,
                color: _receivedPhoto != null ? AppColors.successGreen : AppColors.primaryGreen),
            label: Text(_receivedPhoto != null ? 'Photo taken ✓' : 'Take Photo of Return'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 0), padding: const EdgeInsets.symmetric(vertical: 12)),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (_receivedPhoto != null && !_isSubmitting) ? _confirmReceived : null,
              icon: const Icon(Icons.check_circle, color: Colors.white),
              label: const Text('Confirm Received', style: TextStyle(color: Colors.white, fontSize: 15)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A8A2E),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isSubmitting ? null : _showNotReceivedSheet,
              icon: Icon(Icons.cancel, color: Colors.red[700]),
              label: Text('I Did NOT Receive This', style: TextStyle(color: Colors.red[700], fontSize: 15)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.red[700]!),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Falsely rejecting a legitimate return may result in account suspension.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
