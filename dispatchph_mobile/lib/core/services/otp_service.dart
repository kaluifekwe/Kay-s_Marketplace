import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

/// Email OTP verification (Phase 1 email auth). Talks to the send-otp /
/// verify-otp Edge Functions, which act on auth.uid() — so the caller must be
/// signed in (they are, right after register()). Returns (ok, error?) with a
/// clean user-facing message.
class OtpService {
  static Map<String, String> get _headers {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final session = SupabaseService.auth.currentSession;
    if (session != null && session.accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${session.accessToken}';
    }
    return headers;
  }

  static ({bool ok, String? error}) _result(dynamic data, {String fallback = 'Something went wrong. Please try again.'}) {
    // Prefer the human `message` over the machine `error` code so the user sees
    // e.g. "Couldn't send the code: domain not verified" instead of "resend_failed".
    final raw = data is Map ? (data['message'] ?? data['error']) : null;
    return (ok: false, error: (raw ?? fallback).toString());
  }

  /// Send (or resend) a fresh code to the signed-in user's email.
  /// `alreadyVerified` is true when the account is already email-verified — the
  /// caller should just proceed into the app (no code was sent).
  static Future<({bool ok, bool alreadyVerified, String? error})> sendCode() async {
    try {
      final res = await SupabaseService.client.functions.invoke('send-otp', headers: _headers, body: {});
      if (res.status == 200) {
        final already = res.data is Map && res.data['alreadyVerified'] == true;
        return (ok: true, alreadyVerified: already, error: null);
      }
      final r = _result(res.data, fallback: "We couldn't send the code. Please try again.");
      return (ok: false, alreadyVerified: false, error: r.error);
    } on FunctionException catch (e) {
      final r = _result(e.details, fallback: "We couldn't send the code (${e.status}).");
      return (ok: false, alreadyVerified: false, error: r.error);
    } catch (_) {
      return (ok: false, alreadyVerified: false, error: 'Could not reach the server. Check your connection and try again.');
    }
  }

  /// Verify the 6-digit [code]. On ok:true the account is now email-verified.
  static Future<({bool ok, String? error})> verifyCode(String code) async {
    try {
      final res = await SupabaseService.client.functions.invoke('verify-otp', headers: _headers, body: {'code': code});
      if (res.status == 200) return (ok: true, error: null);
      return _result(res.data, fallback: 'Verification failed. Please try again.');
    } on FunctionException catch (e) {
      return _result(e.details, fallback: 'Verification failed (${e.status}).');
    } catch (_) {
      return (ok: false, error: 'Could not reach the server. Check your connection and try again.');
    }
  }
}
