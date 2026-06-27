import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/phone_input.dart';
import '../../widgets/primary_button.dart';
import 'nin_verification_screen.dart';

class RiderRegistrationScreen extends StatefulWidget {
  final String phone;

  const RiderRegistrationScreen({super.key, required this.phone});

  @override
  State<RiderRegistrationScreen> createState() => _RiderRegistrationScreenState();
}

class _RiderRegistrationScreenState extends State<RiderRegistrationScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _phoneController.text = widget.phone.replaceAll('234', '0');
  }

  void _continue() {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your name')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NinVerificationScreen(
          phone: widget.phone,
          name: _nameController.text.trim(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: AppColors.charcoal,
        title: const Text('Rider Registration'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tell us about\nyourself',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'We need these details to get you started',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppColors.mediumGray,
                    ),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Full name',
                  hintText: 'e.g., Okonkwo Chibueze',
                ),
              ),
              const SizedBox(height: 16),
              PhoneInputField(
                controller: _phoneController,
              ),
              const SizedBox(height: 32),
              PrimaryButton(
                text: 'Continue',
                isLoading: _isLoading,
                onPressed: _continue,
                backgroundColor: AppColors.primaryGreen,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
