import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
import 'home_router.dart';
import 'email_otp_screen.dart';
import 'forgot_password_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email');
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = 'Enter your password');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    print('[Login] Attempting login with email=$email');
    final error = await AuthService.login(email, password);
    if (!mounted) return;

    if (error == null) {
      // Email-verification gate: an account that never finished its OTP must
      // verify before entering the app. Route it back to the OTP screen.
      final verified = await AuthService.isEmailVerified();
      if (!mounted) return;
      if (!verified) {
        final ok = await Navigator.push<bool>(
          context,
          MaterialPageRoute(builder: (_) => EmailOtpScreen(email: email)),
        );
        if (ok != true) {
          await SupabaseService.auth.signOut();
          if (!mounted) return;
          setState(() {
            _isLoading = false;
            _error = 'Please verify your email to continue.';
          });
          return;
        }
      }
      final prefs = await SharedPreferences.getInstance();
      final role = prefs.getString('auth_role') ?? 'buyer';
      final userId = prefs.getString('auth_user_id') ?? '';
      print('[Login] Success! role=$role userId=$userId');
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => HomeRouter(role: role)),
      );
    } else {
      setState(() {
        _error = error;
        _isLoading = false;
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
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              const Icon(Icons.store, size: 48, color: AppColors.primaryGreen),
              const SizedBox(height: 24),
              Text(
                'Welcome back',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 8),
              Text(
                "Log in to your Kay's Market account",
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppColors.mediumGray),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'e.g., chibueze@email.com',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                    tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.errorRed, fontSize: 13)),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ForgotPasswordScreen(initialEmail: _emailController.text.trim()),
                    ),
                  ),
                  child: const Text('Forgot password?', style: TextStyle(color: AppColors.primaryGreen)),
                ),
              ),
              const SizedBox(height: 12),
              PrimaryButton(
                text: 'Log In',
                isLoading: _isLoading,
                onPressed: _login,
                backgroundColor: AppColors.primaryGreen,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
