import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

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

    if (response.status != 200) {
      final data = response.data;
      throw Exception(data is Map ? (data['error'] ?? 'Payment initialization failed') : 'Payment initialization failed');
    }

    return response.data as Map<String, dynamic>;
  }

  /// Verify account name via Paystack Edge Function
  static Future<Map<String, dynamic>> verifyBankAccount({
    required String accountNumber,
    required String bankCode,
  }) async {
    final response = await _client.functions.invoke(
      'paystack-proxy',
      headers: _headers,
      body: {
        'action': 'resolve-account',
        'account_number': accountNumber,
        'bank_code': bankCode,
      },
    ).timeout(_timeout);

    final data = response.data;
    if (response.status != 200 || (data is Map && data['error'] != null)) {
      throw Exception(data is Map ? (data['error'] ?? 'Account verification failed') : 'Account verification failed');
    }
    return data as Map<String, dynamic>;
  }

  /// Create transfer recipient for vendor via Edge Function
  static Future<Map<String, dynamic>> createTransferRecipient({
    required String name,
    required String accountNumber,
    required String bankCode,
  }) async {
    final response = await _client.functions.invoke(
      'paystack-proxy',
      headers: _headers,
      body: {
        'action': 'create-transfer-recipient',
        'name': name,
        'account_number': accountNumber,
        'bank_code': bankCode,
      },
    ).timeout(_timeout);

    final data = response.data;
    if (response.status != 200 || (data is Map && data['error'] != null)) {
      throw Exception(data is Map ? (data['error'] ?? 'Failed to create transfer recipient') : 'Failed to create transfer recipient');
    }
    return data as Map<String, dynamic>;
  }

  /// List all Nigerian banks via Edge Function
  static Future<List<Map<String, dynamic>>> listBanks() async {
    final response = await _client.functions.invoke(
      'paystack-proxy',
      headers: _headers,
      body: {'action': 'list-banks'},
    ).timeout(_timeout);

    final data = response.data;
    if (response.status != 200 || (data is Map && data['error'] != null)) {
      throw Exception(data is Map ? (data['error'] ?? 'Failed to load banks') : 'Failed to load banks');
    }
    return List<Map<String, dynamic>>.from((data as Map)['banks']);
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
    final response = await _client.functions.invoke(
      'release-escrow',
      headers: _headers,
      body: {
        'order_id': orderId,
      },
    ).timeout(_timeout);

    if (response.status != 200) {
      final data = response.data;
      throw Exception(data is Map ? (data['error'] ?? 'Release failed') : 'Release failed');
    }
    return response.data as Map<String, dynamic>;
  }

  /// Process refund — call Edge Function
  static Future<Map<String, dynamic>> processRefund({
    required String orderId,
    String? disputeId,
    String? reason,
    String? refundMethod,
  }) async {
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

    if (response.status != 200) {
      final data = response.data;
      throw Exception(data is Map ? (data['error'] ?? 'Refund failed') : 'Refund failed');
    }
    return response.data as Map<String, dynamic>;
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
