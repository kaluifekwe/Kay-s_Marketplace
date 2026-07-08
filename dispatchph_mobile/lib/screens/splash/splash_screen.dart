import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../core/services/fcm_service.dart';
import '../../core/services/supabase_service.dart';
import '../auth/welcome_screen.dart';
import '../auth/select_state_screen.dart';
import '../auth/home_router.dart';
import '../admin/admin_state_requests_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );
    _controller.forward();
    _checkAuth();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _checkAuth() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    final session = SupabaseService.auth.currentSession;
    final user = SupabaseService.auth.currentUser;
    if (session != null && user != null) {
      final userData = await SupabaseService.client
          .from('users')
          .select('id, email, name, role, store_id, state')
          .eq('id', user.id)
          .maybeSingle();

      if (userData != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_user_id', user.id);
        await prefs.setString('auth_email', userData['email'] ?? '');
        await prefs.setString('auth_name', userData['name'] ?? '');
        await prefs.setString('auth_role', userData['role'] ?? 'buyer');
        await prefs.setString('auth_store_id', userData['store_id'] ?? '');

        if (!mounted) return;
        FCMService.init();
        final role = userData['role'] ?? 'buyer';

        if (role == 'admin') {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AdminStateRequestsScreen()));
          return;
        }

        // Accounts created before the state field existed have state ==
        // null — force a one-time pick before letting them in further.
        if ((role == 'buyer' || role == 'vendor') && userData['state'] == null) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => SelectStateScreen(userId: user.id, role: role)),
          );
          return;
        }

        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => HomeRouter(role: role)));
        return;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString('auth_role');
    final loggedIn = prefs.containsKey('auth_user_id');

    if (!mounted) return;

    if (loggedIn) {
      FCMService.init();
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => HomeRouter(role: role ?? 'buyer')));
    } else {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const WelcomeScreen()));
    }
  }

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
              Color(0xFF1B5E20),
              Color(0xFF2E7D32),
              AppColors.primaryGreen,
            ],
          ),
        ),
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
            Center(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: ScaleTransition(
                  scale: _scaleAnimation,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Glowing icon container
                      Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.riderYellow.withAlpha(30),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.riderYellow.withAlpha(80),
                              blurRadius: 40,
                              spreadRadius: 10,
                            ),
                          ],
                        ),
                        child: Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.riderYellow.withAlpha(20),
                            border: Border.all(
                              color: AppColors.riderYellow.withAlpha(100),
                              width: 2,
                            ),
                          ),
                          child: const Icon(
                            Icons.store_rounded,
                            size: 60,
                            color: AppColors.riderYellow,
                          ),
                        ),
                      ),
                      const SizedBox(height: 40),
                      // Brand name
                      Text(
                        "Kays",
                        style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                              color: AppColors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 42,
                              letterSpacing: 1.5,
                            ),
                      ),
                      const SizedBox(height: 8),
                      // Yellow accent line
                      Container(
                        width: 50,
                        height: 3,
                        decoration: BoxDecoration(
                          color: AppColors.riderYellow,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Market',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: AppColors.riderYellow,
                              fontSize: 20,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 3,
                            ),
                      ),
                      const SizedBox(height: 60),
                      // Loading indicator
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: AppColors.riderYellow.withAlpha(200),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Trust badge at bottom
            Positioned(
              bottom: 60,
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.lock_rounded,
                        color: AppColors.riderYellow.withAlpha(200),
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Secured with Escrow Protection',
                        style: TextStyle(
                          color: AppColors.white.withAlpha(200),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
