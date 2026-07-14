import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/password_strength_indicator.dart';
import '../../core/services/auth_service.dart';

/// In-app password reset: enter email → receive a 6-digit code → set a new
/// password. Reuses the email-OTP pipeline, so there are no email links or
/// deep-links to configure. Same flow for buyers and vendors.
class ForgotPasswordScreen extends StatefulWidget {
  final String? initialEmail;
  const ForgotPasswordScreen({super.key, this.initialEmail});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _codeSent = false; // false = enter email, true = enter code + new password
  bool _loading = false;
  bool _obscure = true;
  String? _error;
  String? _info;
  int _resendIn = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.initialEmail != null) _email.text = widget.initialEmail!;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _startResendCountdown() {
    _resendIn = 60;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_resendIn > 0) _resendIn--;
      });
    });
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter a valid email address');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    final err = await AuthService.requestPasswordReset(email);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (err == null) {
        _codeSent = true;
        _info = 'If that email has an account, a 6-digit code is on its way. Check your inbox and spam.';
        _startResendCountdown();
      } else {
        _error = err;
      }
    });
  }

  Future<void> _resetPassword() async {
    final code = _code.text.trim();
    final pwd = _password.text;
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from your email');
      return;
    }
    if (!PasswordStrengthIndicator.isAcceptable(pwd)) {
      setState(() => _error = 'Password must be at least 8 characters with letters and numbers');
      return;
    }
    if (pwd != _confirm.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    final err = await AuthService.confirmPasswordReset(
      email: _email.text.trim(),
      code: code,
      newPassword: pwd,
    );
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password updated — please log in with your new password.'),
          backgroundColor: AppColors.primaryGreen,
        ),
      );
    } else {
      setState(() {
        _loading = false;
        _error = err;
      });
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
        title: const Text('Reset password'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lock_reset, size: 48, color: AppColors.primaryGreen),
              const SizedBox(height: 16),
              Text(
                _codeSent ? 'Enter code & new password' : 'Forgot your password?',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                _codeSent
                    ? 'We sent a 6-digit code to ${_email.text.trim()}. Enter it below with your new password.'
                    : "Enter your email and we'll send you a code to reset your password.",
                style: const TextStyle(color: AppColors.mediumGray, height: 1.5),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _email,
                enabled: !_codeSent,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email address'),
              ),
              if (_codeSent) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(counterText: '', hintText: '••••••'),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _password,
                  obscureText: _obscure,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'New password',
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                PasswordStrengthIndicator(password: _password.text),
                const SizedBox(height: 16),
                TextField(
                  controller: _confirm,
                  obscureText: _obscure,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Confirm new password',
                    suffixIcon: _confirm.text.isEmpty
                        ? null
                        : Icon(
                            _confirm.text == _password.text ? Icons.check_circle : Icons.error_outline,
                            color: _confirm.text == _password.text ? AppColors.successGreen : AppColors.errorRed,
                            size: 20,
                          ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.errorRed, fontSize: 13)),
              ] else if (_info != null) ...[
                const SizedBox(height: 12),
                Text(_info!, style: const TextStyle(color: AppColors.primaryGreen, fontSize: 13)),
              ],
              const SizedBox(height: 24),
              PrimaryButton(
                text: _codeSent ? 'Reset password' : 'Send reset code',
                isLoading: _loading,
                onPressed: _loading ? null : (_codeSent ? _resetPassword : _sendCode),
                backgroundColor: AppColors.primaryGreen,
              ),
              if (_codeSent) ...[
                const SizedBox(height: 12),
                Center(
                  child: TextButton(
                    onPressed: (_resendIn > 0 || _loading) ? null : _sendCode,
                    child: Text(
                      _resendIn > 0 ? 'Resend code in ${_resendIn}s' : "Didn't get it? Resend code",
                      style: TextStyle(color: _resendIn > 0 ? AppColors.mediumGray : AppColors.primaryGreen),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
