import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import 'face_verification_screen.dart';

class NinVerificationScreen extends StatefulWidget {
  final String phone;
  final String? name;

  const NinVerificationScreen({super.key, required this.phone, this.name});

  @override
  State<NinVerificationScreen> createState() => _NinVerificationScreenState();
}

class _NinVerificationScreenState extends State<NinVerificationScreen> {
  final _ninController = TextEditingController();
  bool _isLoading = false;
  bool _verified = false;

  // Auto-populated data (simulated)
  String _fullName = '';
  String _dob = '';
  String _address = '';

  void _verifyNin() async {
    final nin = _ninController.text.trim();
    if (nin.length != 11) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NIN must be 11 digits')),
      );
      return;
    }

    setState(() => _isLoading = true);

    // Simulate API call to AuthentifyNG / Kora
    await Future.delayed(const Duration(seconds: 2));

    setState(() {
      _isLoading = false;
      _verified = true;
      _fullName = 'Okonkwo Chibueze David';
      _dob = '14/06/1995';
      _address = '14 Eneka Road, Rumuokoro, Port Harcourt';
    });
  }

  void _continue() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FaceVerificationScreen(
          phone: widget.phone,
          nin: _ninController.text.trim(),
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
        title: const Text('Identity Verification'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.fingerprint, size: 48, color: AppColors.primaryGreen),
              const SizedBox(height: 16),
              Text(
                'Verify with NIN',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Enter your National Identification Number (NIN)\nYour details will auto-populate from NIMC.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppColors.mediumGray,
                    ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _ninController,
                keyboardType: TextInputType.number,
                maxLength: 11,
                decoration: InputDecoration(
                  labelText: 'NIN (11 digits)',
                  hintText: '12345678901',
                  suffixIcon: _verified
                      ? const Icon(Icons.check_circle, color: AppColors.successGreen)
                      : null,
                ),
              ),
              if (!_verified) ...[
                const SizedBox(height: 16),
                PrimaryButton(
                  text: 'Verify NIN',
                  isLoading: _isLoading,
                  onPressed: _verifyNin,
                  backgroundColor: AppColors.primaryGreen,
                ),
              ],
              if (_verified) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.primaryGreen.withAlpha(10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primaryGreen.withAlpha(50)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Details from NIMC',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryGreen,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _detailRow('Name', _fullName),
                      _detailRow('DOB', _dob),
                      _detailRow('Address', _address),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                PrimaryButton(
                  text: 'Confirm & Continue →',
                  onPressed: _continue,
                  backgroundColor: AppColors.primaryGreen,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: TextStyle(color: AppColors.mediumGray, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
