import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';
import 'error_text.dart';

/// Account lifecycle actions that aren't plain auth (delete account, etc.).
class AccountService {
  /// Permanently delete the caller's account + data via the delete-account
  /// Edge Function. Throws with a friendly message on failure (e.g. a wallet
  /// balance still needs withdrawing).
  static Future<void> deleteAccount() async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final session = SupabaseService.auth.currentSession;
    if (session != null && session.accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${session.accessToken}';
    }
    try {
      await SupabaseService.client.functions.invoke(
        'delete-account',
        headers: headers,
        body: {},
      );
    } on FunctionException catch (e) {
      throw Exception(friendlyError(e, fallback: "We couldn't delete your account. Please try again."));
    } catch (e) {
      throw Exception(friendlyError(e, fallback: "We couldn't delete your account. Please try again."));
    }
  }
}
