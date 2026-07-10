import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'error_text.dart';
import 'cache_service.dart';

class PaymentService {
  static final _client = Supabase.instance.client;

  // Edge Function calls carry real money operations — on a stalled
  // Nigerian mobile connection these must fail fast with a retryable
  // error instead of leaving the user on an unrecoverable spinner.
  static const _timeout = Duration(seconds: 20);

  static Map<String, String> get _headers {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    final session = _client.auth.currentSession;
    if (session != null && session.accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${session.accessToken}';
    }
    return headers;
  }

  /// Ensure we have a valid Supabase session before calling Edge Functions.
  /// Returns true if session is valid, false if user needs to re-login.
  static Future<bool> ensureSession() async {
    final session = _client.auth.currentSession;
    if (session != null && !session.isExpired) return true;

    // Try to refresh
    try {
      final refreshed = await _client.auth.refreshSession();
      return refreshed.session != null;
    } catch (_) {
      return false;
    }
  }

  /// Initialize Paystack payment — returns authorization_url
  static Future<Map<String, dynamic>> createPayment({
    required String orderId,
    required String buyerId,
    required List<Map<String, dynamic>> vendorOrders,
    required double amount,
    required String email,
  }) async {
    try {
      final response = await _client.functions.invoke(
        'create-payment',
        headers: _headers,
        body: {
          'order_id': orderId,
          'buyer_id': buyerId,
          'vendor_orders': vendorOrders,
          'amount': amount,
          'email': email,
        },
      ).timeout(_timeout);
      return (response.data as Map).cast<String, dynamic>();
    } catch (e) {
      throw Exception(friendlyError(e, fallback: "We couldn't start your payment. Please try again."));
    }
  }

  /// Verify account name via Flutterwave (same provider as payouts).
  static Future<Map<String, dynamic>> verifyBankAccount({
    required String accountNumber,
    required String bankCode,
  }) async {
    try {
      final response = await _client.functions.invoke(
        'flutterwave-proxy',
        headers: _headers,
        body: {
          'action': 'resolve-account',
          'account_number': accountNumber,
          'bank_code': bankCode,
        },
      ).timeout(_timeout);
      final data = response.data;
      if (data is Map && data['error'] != null) {
        final m = data['message'];
        throw Exception(m is String && m.trim().isNotEmpty
            ? m.trim()
            : "We couldn't confirm that account. Check the number and bank.");
      }
      return (data as Map).cast<String, dynamic>();
    } catch (e) {
      throw Exception(friendlyError(e, fallback: "We couldn't confirm that account. Check the number and bank."));
    }
  }

  /// Flutterwave payouts transfer straight to an account number + bank code, so
  /// there's no "recipient" to pre-create (that was a Paystack concept). Kept as
  /// a no-op stub so the existing bank-account save flow doesn't need changing.
  static Future<Map<String, dynamic>> createTransferRecipient({
    required String name,
    required String accountNumber,
    required String bankCode,
  }) async {
    return {'recipient_code': ''};
  }

  /// List all Nigerian banks via Flutterwave.
  static Future<List<Map<String, dynamic>>> listBanks() async {
    // Banks barely change — serve a persisted copy (survives restarts) and only
    // hit the network once a week.
    const cacheKey = 'flw_banks';
    final cached = await CacheService.getPersisted(cacheKey);
    if (cached is List && cached.isNotEmpty) {
      return cached.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    try {
      final response = await _client.functions.invoke(
        'flutterwave-proxy',
        headers: _headers,
        body: {'action': 'list-banks'},
      ).timeout(_timeout);
      final banks = List<Map<String, dynamic>>.from((response.data as Map)['banks']);
      await CacheService.setPersisted(cacheKey, banks, const Duration(days: 7));
      return banks;
    } catch (e) {
      throw Exception(friendlyError(e, fallback: "We couldn't load the bank list. Please try again."));
    }
  }

  /// Save vendor bank account
  static Future<void> saveBankAccount({
    required String userId,
    required String bankName,
    required String bankCode,
    required String accountNumber,
    required String accountName,
    required String recipientCode,
  }) async {
    await _client.from('vendor_bank_accounts').upsert({
      'user_id': userId,
      'bank_name': bankName,
      'bank_code': bankCode,
      'account_number': accountNumber,
      'account_name': accountName,
      'paystack_recipient_code': recipientCode,
      'is_verified': true,
    }, onConflict: 'user_id');
  }

  /// Get vendor bank account
  static Future<Map<String, dynamic>?> getBankAccount(String userId) async {
    final data = await _client
        .from('vendor_bank_accounts')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    return data;
  }

  /// Check if bank account is locked
  static Future<bool> isBankAccountLocked(String userId) async {
    final data = await _client
        .rpc('is_bank_account_locked', params: {'p_user_id': userId});
    return data == true;
  }

  /// Lock bank account for 24 hours
  static Future<void> lockBankAccount(String userId) async {
    await _client
        .from('vendor_bank_accounts')
        .update({'locked_until': DateTime.now().add(const Duration(hours: 24)).toIso8601String()})
        .eq('user_id', userId);
  }

  /// Release escrow — call Edge Function (vendor_id read from order in DB)
  static Future<Map<String, dynamic>> releaseEscrow({
    required String orderId,
  }) async {
    try {
      final response = await _client.functions.invoke(
        'release-escrow',
        headers: _headers,
        body: {'order_id': orderId},
      ).timeout(_timeout);
      return (response.data as Map).cast<String, dynamic>();
    } catch (e) {
      throw Exception(friendlyError(e, fallback: "We couldn't release this payment. Please try again."));
    }
  }

  /// Process refund — call Edge Function
  static Future<Map<String, dynamic>> processRefund({
    required String orderId,
    String? disputeId,
    String? reason,
    String? refundMethod,
  }) async {
    try {
      final response = await _client.functions.invoke(
        'process-refund',
        headers: _headers,
        body: {
          'order_id': orderId,
          'dispute_id': disputeId,
          'reason': reason,
          'refund_method': refundMethod,
        },
      ).timeout(_timeout);
      return (response.data as Map).cast<String, dynamic>();
    } catch (e) {
      throw Exception(friendlyError(e, fallback: "We couldn't process this refund. Please try again."));
    }
  }

  /// Get transactions for an order
  static Future<List<Map<String, dynamic>>> getTransactions(String orderId) async {
    final data = await _client
        .from('transactions')
        .select()
        .eq('order_id', orderId)
        .order('created_at', ascending: true);
    return List<Map<String, dynamic>>.from(data);
  }
}
