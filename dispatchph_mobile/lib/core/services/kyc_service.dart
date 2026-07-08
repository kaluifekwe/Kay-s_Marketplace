import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

/// Buyer identity verification (NIN). A buyer must be `verified` before they can
/// buy; the real enforcement is server-side (create-payment / complete-credit-
/// order reject unverified buyers) — this is the client-side status + submit.
class KycService {
  /// 'none' | 'pending' | 'verified' | 'rejected'
  static Future<String> status() async {
    final uid = SupabaseService.auth.currentUser?.id;
    if (uid == null) return 'none';
    try {
      final row = await SupabaseService.client
          .from('users')
          .select('kyc_status')
          .eq('id', uid)
          .maybeSingle();
      return (row?['kyc_status'] as String?) ?? 'none';
    } catch (e) {
      print('[KycService] status error: $e');
      return 'none';
    }
  }

  static Future<bool> isVerified() async => (await status()) == 'verified';

  /// Verify a NIN via the verify-nin Edge Function. Returns (ok, error?).
  static Future<({bool ok, String? error})> submitNin({
    required String nin,
    String? firstName,
    String? lastName,
  }) async {
    try {
      // Explicitly attach the caller's JWT — verify-nin acts on auth.uid(), so
      // without it the function 401s and verification silently "fails".
      final headers = <String, String>{'Content-Type': 'application/json'};
      final session = SupabaseService.auth.currentSession;
      if (session != null && session.accessToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${session.accessToken}';
      }
      final res = await SupabaseService.client.functions.invoke(
        'verify-nin',
        headers: headers,
        body: {'nin': nin, 'first_name': firstName, 'last_name': lastName},
      );
      if (res.status == 200) return (ok: true, error: null);
      final data = res.data;
      final msg = data is Map
          ? (data['message'] ?? data['error'] ?? 'Verification failed')
          : 'Verification failed';
      return (ok: false, error: msg.toString());
    } on FunctionException catch (e) {
      // invoke() throws on non-2xx — surface the function's actual message
      // (e.g. NIN mismatch, provider error) instead of a generic string.
      final data = e.details;
      final msg = data is Map
          ? (data['message'] ?? data['error'] ?? 'Verification failed')
          : 'Verification failed (${e.status})';
      return (ok: false, error: msg.toString());
    } catch (e) {
      return (ok: false, error: 'Could not reach verification service. Try again.');
    }
  }
}
