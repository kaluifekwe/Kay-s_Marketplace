import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/otp_input.dart';
import '../../widgets/primary_button.dart';
import '../../services/auth_service.dart';
import 'profile_selection_screen.dart';

class OtpVerificationScreen extends StatefulWidget {
  final String phone;
  final bool isSignUp;

  const OtpVerificationScreen({super.key, required this.phone, this.isSignUp = false});

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  final _controller = TextEditingController();
  bool _isLoading = false;
  String? _error;

  Future<void> _verifyOtp() async {
    final otp = _controller.text.trim();
    if (otp.length < 6) {
      setState(() => _error = 'Enter the full 6-digit code');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await AuthService.verifyOtp(widget.phone, otp);
      if (!mounted) return;

      if (response['token'] != null) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => const ProfileSelectionScreen(),
          ),
        );
      } else {
        setState(() => _error = 'Invalid code. Try again.');
      }
    } catch (e) {
      setState(() => _error = 'Verification failed. Try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _skipOtp() {
    final mockToken = 'test_token_${DateTime.now().millisecondsSinceEpoch}';
    AuthService.saveToken(mockToken);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => const ProfileSelectionScreen(),
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
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Verify your\nphone number',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Enter the 6-digit code sent to\n+${widget.phone}',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppColors.mediumGray,
                    ),
              ),
              const SizedBox(height: 32),
              OtpInputField(
                controller: _controller,
                errorText: _error,
                onCompleted: _verifyOtp,
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                text: 'Verify',
                isLoading: _isLoading,
                onPressed: _verifyOtp,
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: () {},
                  child: Text(
                    'Resend code',
                    style: TextStyle(color: AppColors.primaryGreen),
                  ),
                ),
              ),
              if (kDebugMode)
                Center(
                  child: TextButton(
                    onPressed: _skipOtp,
                    child: Text(
                      'Skip Verification (Test Mode)',
                      style: TextStyle(color: AppColors.mediumGray),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
