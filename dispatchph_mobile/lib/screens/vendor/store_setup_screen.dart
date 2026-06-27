import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';

class StoreSetupScreen extends StatefulWidget {
  const StoreSetupScreen({super.key});

  @override
  State<StoreSetupScreen> createState() => _StoreSetupScreenState();
}

class _StoreSetupScreenState extends State<StoreSetupScreen> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Store Setup')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Store Information', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Store name'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descController,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Store description'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Store phone'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _addressController,
              decoration: const InputDecoration(labelText: 'Store address'),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.mediumGray.withAlpha(80)),
                borderRadius: BorderRadius.circular(12),
                color: AppColors.lightGray,
              ),
              child: const Center(
                child: Column(
                  children: [
                    Icon(Icons.add_photo_alternate, size: 40, color: AppColors.mediumGray),
                    SizedBox(height: 8),
                    Text('Tap to add store logo', style: TextStyle(color: AppColors.mediumGray)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
            PrimaryButton(
              text: 'Save Store',
              onPressed: () => Navigator.pop(context),
              backgroundColor: AppColors.primaryGreen,
            ),
          ],
        ),
      ),
    );
  }
}
