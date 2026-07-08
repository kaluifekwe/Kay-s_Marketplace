import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Global crash/error safety net. Two jobs:
///   1. Users never see a raw exception or the grey "error box" — a friendly
///      fallback shows instead (via [ErrorWidget.builder]).
///   2. Support gets the exact cause remotely — every uncaught error is logged
///      to the `client_error_logs` table (best-effort, fire-and-forget), so we
///      can see what happened on a tap/view without asking the customer.
class ErrorReporter {
  static String _appVersion = '';

  static void install({String appVersion = ''}) {
    _appVersion = appVersion;

    // Friendly widget instead of the red/grey "exception on screen" box that a
    // build/render error would otherwise show (e.g. opening a product).
    ErrorWidget.builder = (FlutterErrorDetails details) {
      report(details.exception, details.stack, context: 'widget-build');
      return const _FriendlyErrorBox();
    };

    // Framework errors (build/layout/gesture callbacks).
    final prior = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      report(details.exception, details.stack, context: 'flutter');
      if (kDebugMode) prior?.call(details); // keep the red screen in debug only
    };

    // Uncaught async errors that bubble to the platform.
    PlatformDispatcher.instance.onError = (error, stack) {
      report(error, stack, context: 'platform');
      return true; // handled — don't hard-crash the app
    };
  }

  /// Best-effort log to console + `client_error_logs`. Never throws.
  static void report(Object error, StackTrace? stack, {String context = ''}) {
    try {
      debugPrint('[ErrorReporter/$context] $error');
    } catch (_) {}
    _persist(error, stack, context);
  }

  static String _truncate(String s, int max) => s.length <= max ? s : s.substring(0, max);

  static void _persist(Object error, StackTrace? stack, String context) {
    // Fire-and-forget; swallow everything so logging can never itself crash.
    unawaited(() async {
      try {
        final client = Supabase.instance.client;
        await client.from('client_error_logs').insert({
          'user_id': client.auth.currentUser?.id,
          'context': context,
          'message': _truncate(error.toString(), 500),
          'stack': stack == null ? null : _truncate(stack.toString(), 2000),
          'platform': defaultTargetPlatform.name,
          'app_version': _appVersion,
        });
      } catch (_) {
        // offline / not signed in / table missing — ignore.
      }
    }());
  }
}

class _FriendlyErrorBox extends StatelessWidget {
  const _FriendlyErrorBox();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: Color(0xFF9AA0A6), size: 40),
          SizedBox(height: 12),
          Text(
            'Something went wrong here.\nPlease go back and try again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF5F6368), fontSize: 14),
          ),
        ],
      ),
    );
  }
}
