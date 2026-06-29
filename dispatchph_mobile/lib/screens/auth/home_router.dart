import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/policy_service.dart';
import '../marketplace/home_screen.dart';
import '../vendor/dashboard_screen.dart';
import 'policy_gate_screen.dart';

/// Single entry point into the buyer/vendor app. Sends the user to the policy
/// gate if they have not accepted the current agreement version, otherwise
/// straight to their role home.
///
/// Every login / registration / state-select path navigates here instead of to
/// the role home directly, so bumping kPolicyVersion forces everyone to
/// re-accept on their next entry. (Admins are routed separately and skip this.)
class HomeRouter extends StatelessWidget {
  final String role;

  /// Forwarded to the buyer home so the one-time welcome-credit dialog shows
  /// AFTER the policy gate (set only by the post-registration path).
  final bool showWelcomeCredit;

  const HomeRouter({
    super.key,
    required this.role,
    this.showWelcomeCredit = false,
  });

  Widget _home() => role == 'vendor'
      ? const VendorDashboard()
      : MarketplaceHome(showWelcomeCredit: showWelcomeCredit);

  Future<String?> _resolveGateUserId() async {
    var userId = SupabaseService.auth.currentUser?.id ?? '';
    if (userId.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      userId = prefs.getString('auth_user_id') ?? '';
    }
    // Without a user id we can't gate or record acceptance — let them through
    // rather than trapping them on a blank gate.
    if (userId.isEmpty) return null;
    final accepted = await PolicyService.hasAcceptedCurrent(userId);
    return accepted ? null : userId;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _resolveGateUserId(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final gateUserId = snap.data;
        if (gateUserId != null) {
          return PolicyGateScreen(
            role: role,
            userId: gateUserId,
            home: _home(),
          );
        }
        return _home();
      },
    );
  }
}
