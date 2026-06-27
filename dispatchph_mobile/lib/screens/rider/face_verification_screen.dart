import 'package:flutter/material.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import 'rider_home_screen.dart';

class FaceVerificationScreen extends StatefulWidget {
  final String phone;
  final String nin;

  const FaceVerificationScreen({
    super.key,
    required this.phone,
    required this.nin,
  });

  @override
  State<FaceVerificationScreen> createState() => _FaceVerificationScreenState();
}

class _FaceVerificationScreenState extends State<FaceVerificationScreen> {
  File? _selfie;
  bool _isLoading = false;
  bool _verified = false;
  double _confidence = 0;

  Future<void> _takeSelfie() async {
    final picker = ImagePicker();
    final photo = await picker.pickImage(source: ImageSource.camera);
    if (photo != null) {
      setState(() => _selfie = File(photo.path));
    }
  }

  void _verifyFace() async {
    if (_selfie == null) return;

    setState(() => _isLoading = true);

    // Simulate face match API call
    await Future.delayed(const Duration(seconds: 3));

    setState(() {
      _isLoading = false;
      _verified = true;
      _confidence = 92.5;
    });
  }

  void _done() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const RiderHomeScreen()),
      (route) => false,
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
        title: const Text('Face Verification'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.face, size: 48, color: AppColors.primaryGreen),
              const SizedBox(height: 16),
              Text(
                'Take a selfie',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'We\'ll match your face with your NIMC record.\nMake sure you\'re in good lighting.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppColors.mediumGray,
                    ),
              ),
              const SizedBox(height: 32),
              Center(
                child: GestureDetector(
                  onTap: _verified ? null : _takeSelfie,
                  child: Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.lightGray,
                      border: Border.all(
                        color: _verified ? AppColors.successGreen : AppColors.primaryGreen,
                        width: 3,
                      ),
                      image: _selfie != null
                          ? DecorationImage(
                              image: FileImage(_selfie!),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: _selfie == null
                        ? const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.camera_alt,
                                size: 48,
                                color: AppColors.mediumGray,
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Tap to take selfie',
                                style: TextStyle(color: AppColors.mediumGray),
                              ),
                            ],
                          )
                        : null,
                  ),
                ),
              ),
              if (_verified) ...[
                const SizedBox(height: 24),
                Center(
                  child: Column(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        size: 48,
                        color: AppColors.successGreen,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Face match: ${_confidence.toStringAsFixed(1)}%',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.successGreen,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Identity verified successfully!',
                        style: TextStyle(color: AppColors.mediumGray),
                      ),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              if (_selfie != null && !_verified)
                PrimaryButton(
                  text: 'Verify Face',
                  isLoading: _isLoading,
                  onPressed: _verifyFace,
                  backgroundColor: AppColors.primaryGreen,
                ),
              if (_verified)
                PrimaryButton(
                  text: 'Start Delivering →',
                  onPressed: _done,
                  backgroundColor: AppColors.primaryGreen,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
