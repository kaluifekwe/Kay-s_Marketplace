import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/phone_input.dart';
import '../../widgets/primary_button.dart';
import '../../services/auth_service.dart';
import 'otp_verification_screen.dart';

class PhoneInputScreen extends StatefulWidget {
  final bool isSignUp;

  const PhoneInputScreen({super.key, this.isSignUp = false});

  @override
  State<PhoneInputScreen> createState() => _PhoneInputScreenState();
}

class _PhoneInputScreenState extends State<PhoneInputScreen> {
  final _controller = TextEditingController();
  bool _isLoading = false;
  String? _error;

  Future<void> _sendOtp() async {
    final phone = _controller.text.trim();
    if (phone.length < 10) {
      setState(() => _error = 'Enter a valid phone number');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final fullPhone = '234${phone.substring(phone.length - 10)}';

    if (kDebugMode) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      setState(() => _isLoading = false);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OtpVerificationScreen(phone: fullPhone, isSignUp: widget.isSignUp),
        ),
      );
      return;
    }

    try {
      await AuthService.sendOtp(fullPhone);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OtpVerificationScreen(phone: fullPhone, isSignUp: widget.isSignUp),
        ),
      );
    } catch (e) {
      setState(() => _error = 'Failed to send OTP. Try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
              const Spacer(flex: 2),
              Icon(
                Icons.motorcycle,
                size: 48,
                color: AppColors.primaryGreen,
              ),
              const SizedBox(height: 24),
              Text(
                "Welcome to\nKay's Market",
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Enter your phone number to get started',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppColors.mediumGray,
                    ),
              ),
              const SizedBox(height: 32),
              PhoneInputField(
                controller: _controller,
                errorText: _error,
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                text: 'Continue',
                isLoading: _isLoading,
                onPressed: _sendOtp,
              ),
              const Spacer(flex: 3),
            ],
          ),
        ),
      ),
    );
  }
}
