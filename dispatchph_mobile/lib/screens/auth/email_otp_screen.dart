import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_theme.dart';
import '../../core/services/otp_service.dart';

/// Email OTP gate shown right after signup. Sends a code on entry, lets the user
/// enter it (with a countdown + resend), and pops `true` once verified. The
/// caller (registration screen) only proceeds into the app on a `true` result.
class EmailOtpScreen extends StatefulWidget {
  final String email;
  const EmailOtpScreen({super.key, required this.email});

  @override
  State<EmailOtpScreen> createState() => _EmailOtpScreenState();
}

class _EmailOtpScreenState extends State<EmailOtpScreen> {
  final _codeController = TextEditingController();
  bool _verifying = false;
  bool _resending = false;
  String? _error;
  String? _info;
  int _expiresIn = 600; // 10 minutes
  int _resendIn = 60; // resend cooldown
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sendInitial();
    _startTimer();
  }

  Future<void> _sendInitial() async {
    final r = await OtpService.sendCode();
    if (!mounted) return;
    // Already verified (e.g. an existing account) — nothing to enter, just go in.
    if (r.alreadyVerified) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      if (r.ok) {
        _info = 'Code sent — check your email (and spam folder).';
      } else {
        _error = r.error;
      }
    });
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_expiresIn > 0) _expiresIn--;
        if (_resendIn > 0) _resendIn--;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  String get _clock {
    final m = (_expiresIn ~/ 60).toString().padLeft(2, '0');
    final s = (_expiresIn % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from your email.');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
      _info = null;
    });
    final r = await OtpService.verifyCode(code);
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _verifying = false;
        _error = r.error;
      });
    }
  }

  Future<void> _resend() async {
    if (_resendIn > 0 || _resending) return;
    setState(() {
      _resending = true;
      _error = null;
      _info = null;
    });
    final r = await OtpService.sendCode();
    if (!mounted) return;
    if (r.alreadyVerified) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _resending = false;
      if (r.ok) {
        _resendIn = 60;
        _expiresIn = 600;
        _info = 'A new code is on its way.';
      } else {
        _error = r.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: AppColors.charcoal,
        title: const Text('Verify your email'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.mark_email_read_outlined, size: 48, color: AppColors.primaryGreen),
              const SizedBox(height: 16),
              Text('Enter the 6-digit code', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(
                  style: const TextStyle(color: AppColors.mediumGray, fontSize: 15, height: 1.5),
                  children: [
                    const TextSpan(text: 'We sent a code to '),
                    TextSpan(text: widget.email, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.charcoal)),
                    const TextSpan(text: '. Enter it below to verify your account.'),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: true,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 26, letterSpacing: 10, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '••••••',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onChanged: (v) {
                  if (v.length == 6 && !_verifying) _verify();
                },
              ),
              const SizedBox(height: 8),
              Text(
                _expiresIn > 0 ? 'Code expires in $_clock' : 'Code expired — tap Resend for a new one',
                style: TextStyle(color: _expiresIn > 0 ? AppColors.mediumGray : Colors.red, fontSize: 13),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
              ] else if (_info != null) ...[
                const SizedBox(height: 8),
                Text(_info!, style: TextStyle(color: AppColors.primaryGreen, fontSize: 13)),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _verifying ? null : _verify,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _verifying
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Verify', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: (_resendIn > 0 || _resending) ? null : _resend,
                  child: _resending
                      ? const Text('Sending…')
                      : Text(
                          _resendIn > 0 ? 'Resend code in ${_resendIn}s' : "Didn't get it? Resend code",
                          style: TextStyle(color: _resendIn > 0 ? AppColors.mediumGray : AppColors.primaryGreen),
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
