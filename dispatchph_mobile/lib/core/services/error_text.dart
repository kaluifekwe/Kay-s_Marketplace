import 'dart:async';
import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns ANY error thrown by an Edge Function / Supabase call into a short,
/// human-readable sentence for the UI. It never surfaces a raw error CODE
/// (e.g. `insufficient_balance`) or a stack-y exception dump.
///
/// Order of preference:
///   1. the function's own human `message` field,
///   2. a friendly translation of a known `error` code,
///   3. the provided [fallback] (or a safe generic).
///
/// `invoke()` throws a [FunctionException] on any non-2xx, and its `details`
/// holds the function's JSON body — that's where our `{error, message}` lives.
String friendlyError(Object error, {String? fallback}) {
  final fb = fallback ?? 'Something went wrong. Please try again.';

  if (error is FunctionException) {
    final d = error.details;
    if (d is Map) {
      final msg = d['message'];
      if (msg is String && msg.trim().isNotEmpty) return msg.trim();
      final code = d['error'];
      if (code is String) return _codeToMessage(code) ?? fb;
    }
    return fb;
  }

  if (error is TimeoutException) {
    return 'This is taking too long. Check your connection and try again.';
  }
  if (error is SocketException) {
    return 'No internet connection. Check your network and try again.';
  }

  // A typed Exception that already carries a human message (our services throw
  // Exception(friendlyText)). Strip the wrapper; reject anything that still
  // looks like a bare code or an exception dump.
  final s = error.toString().replaceFirst('Exception: ', '').trim();
  if (s.isEmpty || s.startsWith('FunctionException') || _looksLikeCode(s)) return fb;
  return s;
}

/// A bare machine code like `insufficient_balance` — never show these to users.
bool _looksLikeCode(String s) =>
    !s.contains(' ') && RegExp(r'^[a-z0-9]+(_[a-z0-9]+)+$').hasMatch(s);

/// Known error codes returned by our Edge Functions → friendly copy. Unknown
/// codes return null so the caller falls back to a context-specific message.
String? _codeToMessage(String code) {
  switch (code) {
    case 'insufficient_balance':
      return "You don't have enough in your wallet. Add money and try again.";
    case 'no_bank_account':
      return 'Add a bank account to receive your withdrawal.';
    case 'exceeds_withdrawable':
      return 'That is more than you can withdraw right now.';
    case 'pin_not_set':
      return 'Set up your withdrawal PIN first.';
    case 'pin_wrong':
      return 'Incorrect PIN. Please try again.';
    case 'pin_locked':
      return 'Too many wrong PIN attempts. Please try again later.';
    case 'pin_invalid':
      return 'Enter your 4-digit withdrawal PIN.';
    case 'pin_exists':
      return 'You already have a withdrawal PIN.';
    case 'kyc_required':
    case 'identity_required':
      return 'Verify your identity to continue.';
    case 'kyc_rejected':
      return "We couldn't verify your identity. Check your details and try again.";
    case 'not_verified':
      return 'Verify your identity before you can do this.';
    case 'intrastate_only':
      return 'You can only buy from vendors in your state.';
    case 'out_of_stock':
      return 'One or more items just went out of stock.';
    case 'price_mismatch':
      return 'A price changed. Please review your cart and try again.';
    case 'no_couriers':
      return 'No courier covers this route. Chat the vendor to arrange delivery.';
    case 'has_dispute':
    case 'payout_blocked':
      return 'This order is on hold and cannot be paid out right now.';
    case 'unauthorized':
    case 'Unauthorized':
      return 'Please sign in again to continue.';
    default:
      return null;
  }
}
