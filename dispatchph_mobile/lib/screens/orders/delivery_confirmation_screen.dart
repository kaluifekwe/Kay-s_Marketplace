import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../core/models/models.dart';
import '../../core/blocs/order_bloc.dart';
import '../../core/services/auth_service.dart';
import '../../theme/app_theme.dart';

class DeliveryConfirmationScreen extends StatefulWidget {
  final Order order;

  const DeliveryConfirmationScreen({super.key, required this.order});

  @override
  State<DeliveryConfirmationScreen> createState() => _DeliveryConfirmationScreenState();
}

class _DeliveryConfirmationScreenState extends State<DeliveryConfirmationScreen> {
  File? _deliveryPhoto;
  bool _isSubmitting = false;

  Future<void> _pickPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 80);
    if (picked != null) {
      setState(() {
        _deliveryPhoto = File(picked.path);
      });
    }
  }

  Future<void> _confirmDelivery() async {
    // A photo is welcome but not required — see OrderCubit.confirmDelivery.
    // Blocking on it turned "I got my order" into a chore and left orders
    // unconfirmed, which is worse for everyone than a missing picture.

    // Final, explicit warning: confirmation is irreversible. This is the moment
    // the buyer waives any dispute/refund, so make the consequence unmistakable
    // BEFORE we release the money to the vendor.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm & release payment?'),
        content: const Text(
          "By confirming, you're saying you received this order and it's exactly what you ordered.\n\n"
          "The payment will be released to the vendor and this CANNOT be reversed or refunded.\n\n"
          "If anything is wrong or you haven't received it, tap \"Not yet\" and report a problem instead.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.successGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Yes, confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isSubmitting = true);

    final buyerId = await AuthService.getUserId();
    final success = await context.read<OrderCubit>().confirmDelivery(
      orderId: widget.order.id,
      buyerId: buyerId,
      deliveryPhotoPath: _deliveryPhoto?.path,
    );

    setState(() => _isSubmitting = false);

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Delivery confirmed! Payment released to vendor.'),
            backgroundColor: AppColors.successGreen,
          ),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to confirm delivery. Please try again.'),
            backgroundColor: AppColors.errorRed,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = jsonDecode(widget.order.items) as List;
    final itemNames = items.map((i) => i['name'] ?? 'Item').join(', ');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm Delivery'),
        backgroundColor: AppColors.primaryBlue,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Warning banner
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warningOrange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.warningOrange),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, color: AppColors.warningOrange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Adding a photo is optional, but it protects you if anything is disputed later.',
                      style: TextStyle(color: AppColors.warningOrange, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Order details
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Order Details', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const Divider(),
                    _buildDetailRow('Order ID', '#${widget.order.id.substring(0, 8)}'),
                    _buildDetailRow('Items', itemNames),
                    _buildDetailRow('Total', '₦${widget.order.total.toStringAsFixed(0)}'),
                    _buildDetailRow('Status', widget.order.status.toUpperCase()),
                    if (widget.order.shippedAt != null)
                      _buildDetailRow('Shipped', DateFormat('MMM d, h:mm a').format(widget.order.shippedAt!)),
                    if (widget.order.riderName != null)
                      _buildDetailRow('Rider', widget.order.riderName!),
                    if (widget.order.deliveryMethod != null)
                      _buildDetailRow('Delivery Method', widget.order.deliveryMethod!),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Shipping proof from vendor
            if (widget.order.shippingProofUrl != null) ...[
              const Text('Vendor\'s Shipping Photo', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  widget.order.shippingProofUrl!,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    height: 200,
                    color: AppColors.lightGray,
                    child: const Center(child: Text('Could not load image')),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Delivery photo upload
            const Text('Add a Photo (optional)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'A photo of what you received is useful evidence if you later report a problem. You can confirm without one.',
              style: TextStyle(color: AppColors.mediumGray, fontSize: 13),
            ),
            const SizedBox(height: 12),

            GestureDetector(
              onTap: _isSubmitting ? null : _pickPhoto,
              child: Container(
                height: 250,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppColors.lightGray,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.mediumGray.withOpacity(0.3)),
                ),
                child: _deliveryPhoto != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(_deliveryPhoto!, fit: BoxFit.cover),
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.camera_alt, size: 64, color: AppColors.mediumGray),
                          const SizedBox(height: 8),
                          const Text('Tap to add photo', style: TextStyle(color: AppColors.mediumGray)),
                          const SizedBox(height: 4),
                          const Text('(Optional)', style: TextStyle(color: AppColors.mediumGray, fontSize: 12)),
                        ],
                      ),
              ),
            ),

            if (_deliveryPhoto != null) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _isSubmitting ? null : _pickPhoto,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retake'),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 24),

            // Confirm button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _confirmDelivery,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.successGreen,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle),
                          SizedBox(width: 8),
                          Text('Confirm Delivery & Release Payment', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        ],
                      ),
              ),
            ),

            const SizedBox(height: 16),

            // Auto-release info
            if (widget.order.autoReleaseAt != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.escrowBlue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.timer, color: AppColors.escrowBlue, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Auto-release: ${DateFormat('MMM d, h:mm a').format(widget.order.autoReleaseAt!)}',
                        style: const TextStyle(color: AppColors.escrowBlue),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: const TextStyle(color: AppColors.mediumGray)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}
