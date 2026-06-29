import '../constants/app_policy.dart';
import 'supabase_service.dart';

/// Reads and records acceptance of the current Buyer & Vendor Agreement
/// version. Backed by the policy_acceptances table (RLS: a user only ever
/// sees/writes their own rows).
class PolicyService {
  static String get currentVersion => kPolicyVersion;

  /// Whether [userId] has accepted the CURRENT policy version.
  ///
  /// On any error we fail closed (return false → the gate is shown) rather than
  /// letting a user into the app without a recorded acceptance.
  static Future<bool> hasAcceptedCurrent(String userId) async {
    try {
      final row = await SupabaseService.client
          .from('policy_acceptances')
          .select('id')
          .eq('user_id', userId)
          .eq('policy_version', kPolicyVersion)
          .maybeSingle();
      return row != null;
    } catch (e) {
      print('[PolicyService] hasAcceptedCurrent error: $e');
      return false;
    }
  }

  /// Record acceptance of the current policy version. Idempotent — a repeat
  /// acceptance for the same user + version is ignored by the unique index.
  static Future<void> acceptCurrent({
    required String userId,
    required String role,
  }) async {
    await SupabaseService.client.from('policy_acceptances').upsert({
      'user_id': userId,
      'role': role,
      'policy_version': kPolicyVersion,
    }, onConflict: 'user_id,policy_version', ignoreDuplicates: true);
  }

  /// When [userId] accepted the current version, in local time, or null.
  static Future<DateTime?> acceptedAt(String userId) async {
    try {
      final row = await SupabaseService.client
          .from('policy_acceptances')
          .select('accepted_at')
          .eq('user_id', userId)
          .eq('policy_version', kPolicyVersion)
          .maybeSingle();
      final ts = row?['accepted_at'] as String?;
      return ts == null ? null : DateTime.tryParse(ts)?.toLocal();
    } catch (e) {
      print('[PolicyService] acceptedAt error: $e');
      return null;
    }
  }
}
