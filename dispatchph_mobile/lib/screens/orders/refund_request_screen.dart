import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/models/models.dart';
import '../../core/blocs/dispute_bloc.dart';
import '../../core/services/auth_service.dart';
import '../../theme/app_theme.dart';

class RefundRequestScreen extends StatefulWidget {
  final Order order;

  const RefundRequestScreen({super.key, required this.order});

  @override
  State<RefundRequestScreen> createState() => _RefundRequestScreenState();
}

class _RefundRequestScreenState extends State<RefundRequestScreen> {
  final _reasonController = TextEditingController();
  final _explanationController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();
  String? _selectedIssueType;
  final List<File> _evidencePhotos = [];
  File? _videoFile;
  bool _isSubmitting = false;
  bool _isCheckingEligibility = true;
  String? _ineligibleReason;
  bool _onlyNotReceivedAllowed = false;
  String? _restrictionNotice;

  bool get _videoRequired => widget.order.total > 50000;

  static const _allIssueTypes = [
    {'value': 'wrong_item', 'label': 'Wrong item received'},
    {'value': 'damaged', 'label': 'Item damaged in transit'},
    {'value': 'not_as_described', 'label': 'Item not as described'},
    {'value': 'not_received', 'label': 'Item not received at all'},
  ];

  List<Map<String, String>> get _issueTypes => _onlyNotReceivedAllowed
      ? _allIssueTypes.where((t) => t['value'] == 'not_received').toList()
      : _allIssueTypes;

  @override
  void initState() {
    super.initState();
    _checkEligibility();
  }

  Future<void> _checkEligibility() async {
    final buyerId = await AuthService.getUserId();
    if (!mounted) return;
    final result = await context.read<DisputeCubit>().checkDisputeEligibility(
      orderId: widget.order.id,
      buyerId: buyerId,
      vendorId: widget.order.vendorId,
    );
    if (mounted) {
      setState(() {
        if (result.eligible) {
          _ineligibleReason = null;
        } else if (result.windowClosedButNotReceivedAllowed) {
          _ineligibleReason = null;
          _onlyNotReceivedAllowed = true;
          _restrictionNotice = result.reason;
          _selectedIssueType = 'not_received';
        } else {
          _ineligibleReason = result.reason;
        }
        _isCheckingEligibility = false;
      });
    }
  }

  Future<void> _pickPhoto() async {
    if (_evidencePhotos.length >= 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum 5 photos allowed')),
      );
      return;
    }
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 80);
    if (picked != null) {
      setState(() {
        _evidencePhotos.add(File(picked.path));
      });
    }
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final picked = await picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(seconds: 60));
    if (picked != null) {
      setState(() => _videoFile = File(picked.path));
    }
  }

  void _removePhoto(int index) {
    setState(() {
      _evidencePhotos.removeAt(index);
    });
  }

  Future<void> _submitRefundRequest() async {
    if (_selectedIssueType == null) {
      _showError('Please select an issue type');
      return;
    }
    if (_reasonController.text.trim().length < 50) {
      _showError('Please describe the issue in at least 50 characters');
      return;
    }
    if (_phoneController.text.trim().isEmpty) {
      _showError('Please provide your active phone number');
      return;
    }
    if (_addressController.text.trim().isEmpty) {
      _showError('Please provide your delivery address');
      return;
    }
    if (_evidencePhotos.length < 2) {
      _showError('Please take at least 2 photos as evidence (camera only)');
      return;
    }
    if (_videoRequired && _videoFile == null) {
      _showError('A short video is required for orders above ₦50,000');
      return;
    }

    setState(() => _isSubmitting = true);

    final buyerId = await AuthService.getUserId();
    final vendorId = widget.order.vendorId;

    // Re-check with the actual issue type now selected — guards against the
    // window/status changing (e.g. auto-release firing) between when this
    // screen loaded and now, and is what actually lets "not_received"
    // bypass a closed window (the initial check above didn't know the type).
    final finalCheck = await context.read<DisputeCubit>().checkDisputeEligibility(
      orderId: widget.order.id,
      buyerId: buyerId,
      vendorId: vendorId,
      issueType: _selectedIssueType,
    );
    if (!finalCheck.eligible) {
      setState(() => _isSubmitting = false);
      _showError(finalCheck.reason ?? 'This dispute can no longer be submitted.');
      return;
    }

    final success = await context.read<DisputeCubit>().createDispute(
      orderId: widget.order.id,
      buyerId: buyerId,
      vendorId: vendorId,
      reason: _reasonController.text.trim().substring(0, _reasonController.text.trim().length.clamp(0, 80)),
      issueType: _selectedIssueType!,
      buyerPhone: _phoneController.text.trim(),
      deliveryAddress: _addressController.text.trim(),
      explanation: _reasonController.text.trim(),
      evidencePaths: _evidencePhotos.map((f) => f.path).toList(),
      videoPath: _videoFile?.path,
    );

    setState(() => _isSubmitting = false);

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Dispute submitted. The vendor has 24 hours to respond.'),
            backgroundColor: AppColors.successGreen,
          ),
        );
        Navigator.pop(context);
      } else {
        _showError('Failed to submit dispute. Please try again.');
      }
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.errorRed),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isCheckingEligibility) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_ineligibleReason != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Open Dispute')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.block, size: 48, color: AppColors.errorRed),
              const SizedBox(height: 16),
              Text(_ineligibleReason!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Open Dispute'),
        backgroundColor: AppColors.errorRed,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_onlyNotReceivedAllowed && _restrictionNotice != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warningOrange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.warningOrange),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: AppColors.warningOrange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_restrictionNotice!, style: const TextStyle(color: AppColors.warningOrange, fontSize: 13)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.errorRed.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.errorRed),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: AppColors.errorRed),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Camera photos only — gallery uploads are not accepted. False disputes lead to a strike; 3 strikes flags your account.',
                      style: TextStyle(color: AppColors.errorRed, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            const Text('Issue Type *', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.mediumGray.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: _issueTypes.map((type) {
                  return RadioListTile<String>(
                    title: Text(type['label']!),
                    value: type['value']!,
                    groupValue: _selectedIssueType,
                    onChanged: (value) => setState(() => _selectedIssueType = value),
                    activeColor: AppColors.primaryBlue,
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),

            const Text('Describe the issue *', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Minimum 50 characters (${_reasonController.text.trim().length}/50)',
                style: const TextStyle(color: AppColors.mediumGray, fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              controller: _reasonController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Describe exactly what happened...',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 16),

            const Text('Active Phone Number *', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _phoneController,
              decoration: const InputDecoration(
                hintText: 'Your current active phone number',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.phone),
              ),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 16),

            const Text('Delivery Address *', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _addressController,
              decoration: const InputDecoration(
                hintText: 'Your delivery address (e.g., No 5, Ikorodu Road, Lagos)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.location_on),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                const Text('Evidence Photos (camera only) *', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Text('(${_evidencePhotos.length}/5, min 2)', style: const TextStyle(color: AppColors.mediumGray)),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ...List.generate(_evidencePhotos.length, (index) {
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
                          child: Image.file(_evidencePhotos[index], fit: BoxFit.cover),
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () => _removePhoto(index),
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
                if (_evidencePhotos.length < 5)
                  GestureDetector(
                    onTap: _isSubmitting ? null : _pickPhoto,
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
            const SizedBox(height: 16),

            if (_videoRequired) ...[
              const Text('Video Evidence (required for orders > ₦50,000) *',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _isSubmitting ? null : _pickVideo,
                icon: const Icon(Icons.videocam),
                label: Text(_videoFile == null ? 'Record Video' : 'Video recorded ✓'),
              ),
              const SizedBox(height: 16),
            ],

            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _submitRefundRequest,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.errorRed,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isSubmitting
                    ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Submit Dispute', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 16),

            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.escrowBlue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: AppColors.escrowBlue, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The vendor has 24 hours to respond. If they miss it, this escalates to admin automatically. Admin makes the final call — refunds are full amount only, no partial refunds.',
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
