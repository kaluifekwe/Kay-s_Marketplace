import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';

class ActiveDeliveryScreen extends StatefulWidget {
  const ActiveDeliveryScreen({super.key});

  @override
  State<ActiveDeliveryScreen> createState() => _ActiveDeliveryScreenState();
}

class _ActiveDeliveryScreenState extends State<ActiveDeliveryScreen> {
  String _step = 'to_pickup'; // to_pickup, picked_up, complete
  File? _podPhoto;

  void _markPickedUp() {
    setState(() => _step = 'picked_up');
  }

  Future<void> _takePodPhoto() async {
    final picker = ImagePicker();
    final photo = await picker.pickImage(source: ImageSource.camera);
    if (photo != null) {
      setState(() {
        _podPhoto = File(photo.path);
        _step = 'complete';
      });
    }
  }

  void _completeDelivery() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Delivery completed! ₦3,500 earned')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const Text('Active Delivery'),
        foregroundColor: AppColors.white,
      ),
      body: Column(
        children: [
          Container(
            height: 220,
            color: AppColors.mediumGray.withAlpha(40),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.map, size: 48, color: AppColors.mediumGray),
                  const SizedBox(height: 8),
                  Text(
                    _step == 'to_pickup'
                        ? 'Navigate to pickup'
                        : _step == 'picked_up'
                            ? 'Navigate to drop-off'
                            : 'Delivered!',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    _step == 'to_pickup'
                        ? 'Rumuokoro Market, opposite Shoprite'
                        : 'GRA Phase 2, Plot 5 Aba Road',
                    style: TextStyle(color: AppColors.mediumGray, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: AppColors.primaryGreen,
                            child: Icon(Icons.person, color: AppColors.white),
                          ),
                          title: const Text('Chidi (Sender)'),
                          subtitle: const Text('08031234567'),
                          trailing: IconButton(
                            icon: const Icon(Icons.phone, color: AppColors.primaryGreen),
                            onPressed: () {},
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: AppColors.riderYellow,
                            child: Icon(Icons.person_outline, color: AppColors.charcoal),
                          ),
                          title: const Text('Esther (Recipient)'),
                          subtitle: const Text('07098765432'),
                          trailing: IconButton(
                            icon: const Icon(Icons.phone, color: AppColors.primaryGreen),
                            onPressed: () {},
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        _stepRow('Pickup from Rumuokoro Market', _step != 'to_pickup'),
                        _stepRow('Deliver to GRA Phase 2', _step == 'complete'),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (_step == 'to_pickup')
                    PrimaryButton(
                      text: 'Mark as Picked Up',
                      backgroundColor: AppColors.primaryGreen,
                      onPressed: _markPickedUp,
                    ),
                  if (_step == 'picked_up')
                    PrimaryButton(
                      text: 'Take Photo of Delivery',
                      backgroundColor: AppColors.primaryGreen,
                      onPressed: _takePodPhoto,
                    ),
                  if (_step == 'complete')
                    Column(
                      children: [
                        if (_podPhoto != null)
                          Container(
                            height: 100,
                            decoration: BoxDecoration(
                              image: DecorationImage(
                                image: FileImage(_podPhoto!),
                                fit: BoxFit.cover,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        const SizedBox(height: 12),
                        PrimaryButton(
                          text: 'Complete Delivery',
                          backgroundColor: AppColors.primaryGreen,
                          onPressed: _completeDelivery,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepRow(String text, bool done) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: done ? AppColors.successGreen : AppColors.mediumGray,
            size: 20,
          ),
          const SizedBox(width: 12),
          Text(text, style: TextStyle(color: done ? AppColors.successGreen : AppColors.charcoal)),
        ],
      ),
    );
  }
}
