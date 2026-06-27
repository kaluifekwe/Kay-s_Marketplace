import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'login_screen.dart';
import 'profile_selection_screen.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.primaryGreen,
              AppColors.darkGreen,
              Color(0xFF0F5C1A),
            ],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              // Decorative circles
              Positioned(
                top: -80,
                right: -60,
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withAlpha(15),
                  ),
                ),
              ),
              Positioned(
                bottom: -120,
                left: -80,
                child: Container(
                  width: 300,
                  height: 300,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withAlpha(10),
                  ),
                ),
              ),
              // Main content
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    const Spacer(flex: 3),
                    // Premium icon container
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(20),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.riderYellow.withAlpha(80),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(30),
                            blurRadius: 30,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.store_rounded,
                        size: 60,
                        color: AppColors.riderYellow,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      "Kay's",
                      style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                            color: AppColors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 38,
                            letterSpacing: 1.2,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 40,
                      height: 3,
                      decoration: BoxDecoration(
                        color: AppColors.riderYellow,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Marketplace',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: AppColors.riderYellow,
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 2,
                          ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Buy, sell, and deliver\nwith escrow protection',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withAlpha(200),
                        fontSize: 15,
                        height: 1.5,
                      ),
                    ),
                    const Spacer(flex: 3),
                    // Sign Up button with shadow
                    SizedBox(
                      width: double.infinity,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.riderYellow.withAlpha(80),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: ElevatedButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ProfileSelectionScreen()),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.riderYellow,
                            foregroundColor: AppColors.charcoal,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          child: const Text('Sign Up'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Log In button with shadow
                    SizedBox(
                      width: double.infinity,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.white.withAlpha(30),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: OutlinedButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const LoginScreen()),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.white,
                            side: BorderSide(color: Colors.white.withAlpha(200), width: 2),
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          child: const Text('Log In'),
                        ),
                      ),
                    ),
                    const Spacer(flex: 2),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
