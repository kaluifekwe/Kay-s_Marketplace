import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../core/models/models.dart';
import '../../core/blocs/order_bloc.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/supabase_service.dart';
import '../../theme/app_theme.dart';

class VendorShippingScreen extends StatefulWidget {
  final Order order;
  final List<Map<String, dynamic>> items;

  const VendorShippingScreen({super.key, required this.order, required this.items});

  @override
  State<VendorShippingScreen> createState() => _VendorShippingScreenState();
}

class _VendorShippingScreenState extends State<VendorShippingScreen> {
  final _riderNameController = TextEditingController();
  final _riderPhoneController = TextEditingController();
  String _selectedDeliveryMethod = 'dispatch_rider';
  final List<File> _preShipPhotos = [];
  bool _isSubmitting = false;

  final List<Map<String, String>> _deliveryMethods = [
    {'value': 'dispatch_rider', 'label': 'Dispatch Rider'},
    {'value': 'courier', 'label': 'Courier Service'},
    {'value': 'self_delivery', 'label': 'Self Delivery'},
    {'value': 'pickup', 'label': 'Buyer Pickup'},
  ];

  Future<void> _pickPreShipPhoto() async {
    if (_preShipPhotos.length >= 5) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 80);
    if (picked != null) {
      setState(() => _preShipPhotos.add(File(picked.path)));
    }
  }

  void _removePreShipPhoto(int index) {
    setState(() => _preShipPhotos.removeAt(index));
  }

  Future<void> _markAsShipped() async {
    if (_riderNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter rider name'),
          backgroundColor: AppColors.errorRed,
        ),
      );
      return;
    }

    if (_riderPhoneController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter rider phone number'),
          backgroundColor: AppColors.errorRed,
        ),
      );
      return;
    }

    if (_preShipPhotos.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Take at least 2 camera photos of the packaged item before shipping'),
          backgroundColor: AppColors.errorRed,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final vendorId = await context.read<OrderCubit>().state.vendorOrders
        .where((o) => o.id == widget.order.id)
        .map((o) => o.vendorId)
        .firstOrNull ?? '';

    final preShipUrls = <String>[];
    for (final photo in _preShipPhotos) {
      final url = await StorageService.uploadShippingProof(orderId: widget.order.id, filePath: photo.path);
      if (url != null) preShipUrls.add(url);
    }

    await context.read<OrderCubit>().markShipped(
      orderId: widget.order.id,
      vendorId: vendorId,
      riderName: _riderNameController.text.trim(),
      riderPhone: _riderPhoneController.text.trim(),
      deliveryMethod: _selectedDeliveryMethod,
      shippingProofPath: null,
    );

    await SupabaseService.client.from('orders').update({
      'pre_ship_photos': jsonEncode(preShipUrls),
      'shipping_proof_url': preShipUrls.isNotEmpty ? preShipUrls.first : null,
    }).eq('id', widget.order.id);

    setState(() => _isSubmitting = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Order marked as shipped!'),
          backgroundColor: AppColors.successGreen,
        ),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat('#,##0');
    final itemNames = widget.items.map((i) => '${i['name']} x${i['quantity'] ?? 1}').join('\n');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ship Order'),
        backgroundColor: AppColors.primaryBlue,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Order summary
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Order Summary', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const Divider(),
                    Text(itemNames, style: const TextStyle(height: 1.5)),
                    const SizedBox(height: 8),
                    Text(
                      'Total: ₦${format.format(widget.order.total)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Delivery method
            const Text('Delivery Method *', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.mediumGray.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: _deliveryMethods.map((method) {
                  return RadioListTile<String>(
                    title: Text(method['label']!),
                    value: method['value']!,
                    groupValue: _selectedDeliveryMethod,
                    onChanged: (value) {
                      setState(() => _selectedDeliveryMethod = value!);
                    },
                    activeColor: AppColors.primaryBlue,
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),

            // Rider details
            const Text('Rider Details *', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _riderNameController,
              decoration: const InputDecoration(
                labelText: 'Rider Name',
                hintText: 'Enter rider\'s name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _riderPhoneController,
              decoration: const InputDecoration(
                labelText: 'Rider Phone',
                hintText: 'Enter rider\'s phone number',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.phone),
              ),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 16),

            // Pre-ship photos (camera only, required)
            Row(
              children: [
                const Text('Pre-Ship Photos (camera only) *', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Text('(${_preShipPhotos.length}/5, min 2)', style: const TextStyle(color: AppColors.mediumGray)),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Take at least 2 photos of the packaged item before handing it to the rider. Required as proof if a dispute is opened.',
              style: TextStyle(color: AppColors.mediumGray, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ...List.generate(_preShipPhotos.length, (index) {
                  return Stack(
                    children: [
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.mediumGray.withOpacity(0.3)),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(_preShipPhotos[index], fit: BoxFit.cover),
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () => _removePreShipPhoto(index),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                            child: const Icon(Icons.close, size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  );
                }),
                if (_preShipPhotos.length < 5)
                  GestureDetector(
                    onTap: _isSubmitting ? null : _pickPreShipPhoto,
                    child: Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        color: AppColors.lightGray,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.mediumGray.withOpacity(0.3)),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.camera_alt, size: 32, color: AppColors.mediumGray),
                          SizedBox(height: 4),
                          Text('Take Photo', style: TextStyle(fontSize: 12, color: AppColors.mediumGray)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 24),

            // Ship button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _markAsShipped,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryBlue,
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
                          Icon(Icons.local_shipping),
                          SizedBox(width: 8),
                          Text('Mark as Shipped', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        ],
                      ),
              ),
            ),

            const SizedBox(height: 16),

            // Info
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.escrowBlue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: AppColors.escrowBlue, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'After shipping, the buyer has 24 hours to confirm delivery. Payment will be released upon confirmation.',
                      style: TextStyle(color: AppColors.escrowBlue, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
