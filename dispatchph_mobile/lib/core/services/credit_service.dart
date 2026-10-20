import 'package:supabase_flutter/supabase_flutter.dart';
import 'error_text.dart';

class CreditService {
  static final _client = Supabase.instance.client;

  // See PaymentService._timeout — same rationale: these calls move money
  // and must fail fast on a stalled connection instead of hanging forever.
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

  /// Get buyer's credit balance
  static Future<double> getBalance(String buyerId) async {
    try {
      final data = await _client
          .from('users')
          .select('kays_credit')
          .eq('id', buyerId)
          .maybeSingle();
      return (data?['kays_credit'] as num?)?.toDouble() ?? 0;
    } catch (e) {
      print('[CreditService] getBalance error: $e');
      return 0;
    }
  }

  /// Get credit transaction history
  static Future<List<Map<String, dynamic>>> getHistory(String buyerId) async {
    try {
      final data = await _client
          .from('credit_transactions')
          .select('id, buyer_id, amount, type, order_id, description, expires_at, created_at')
          .eq('buyer_id', buyerId)
          .order('created_at', ascending: false)
          .limit(50);
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      print('[CreditService] getHistory error: $e');
      return [];
    }
  }

  /// Trigger cashback after delivery confirmation via Edge Function
  static Future<Map<String, dynamic>?> awardCashback({
    required String orderId,
    required String buyerId,
  }) async {
    try {
      final response = await _client.functions.invoke(
        'cashback-credit',
        headers: _headers,
        body: {
          'order_id': orderId,
          'buyer_id': buyerId,
        },
      ).timeout(_timeout);

      if (response.status == 200) {
        return response.data as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      print('[CreditService] awardCashback error: $e');
      return null;
    }
  }

  /// Use credit for payment (deduct from balance).
  /// Deduction happens atomically via the `spend_kays_credit` RPC so two
  /// concurrent spends can't both pass a check-then-write race and
  /// overdraw the balance.
  static Future<bool> useCredit({
    required String buyerId,
    required double amount,
    required String orderId,
  }) async {
    try {
      final result = await _client.rpc('spend_kays_credit', params: {
        'p_user_id': buyerId,
        'p_amount': amount,
      });

      // RPC returns null/no row when kays_credit < amount (insufficient funds).
      if (result == null) return false;

      await _client.from('credit_transactions').insert({
        'buyer_id': buyerId,
        'amount': -amount,
        'type': 'used',
        'order_id': orderId,
        'description': 'Used for order payment',
      });

      return true;
    } catch (e) {
      print('[CreditService] useCredit error: $e');
      return false;
    }
  }

  /// Complete a checkout that's fully covered by Kay's Credit — creates a
  /// real order per vendor and pays them out via the normal escrow flow,
  /// instead of just deducting credit with no order (the bug this fixes).
  /// Only supports credit fully covering the order total.
  static Future<Map<String, dynamic>> completeCreditOrder({
    required String buyerId,
    required List<Map<String, dynamic>> vendorOrders,
  }) async {
    try {
      final response = await _client.functions.invoke(
        'complete-credit-order',
        headers: _headers,
        body: {
          'buyer_id': buyerId,
          'vendor_orders': vendorOrders,
        },
      ).timeout(_timeout);
      return (response.data as Map).cast<String, dynamic>();
    } catch (e) {
      throw Exception(friendlyError(e, fallback: "We couldn't place your order. Please try again."));
    }
  }

  /// Process refund via Edge Function with refund_method
  static Future<Map<String, dynamic>> processRefund({
    required String orderId,
    String? disputeId,
    String? reason,
    String refundMethod = 'card',
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

  /// Verify buyer bank account via Edge Function
  static Future<Map<String, dynamic>> verifyBankAccount({
    required String buyerId,
    required String accountNumber,
    required String bankCode,
  }) async {
    try {
      final response = await _client.functions.invoke(
        'buyer-bank-account',
        headers: _headers,
        body: {
          'action': 'verify',
          'buyer_id': buyerId,
          'account_number': accountNumber,
          'bank_code': bankCode,
        },
      ).timeout(_timeout);
      return (response.data as Map).cast<String, dynamic>();
    } catch (e) {
      throw Exception(friendlyError(e, fallback: "We couldn't confirm that account. Check the number and bank."));
    }
  }

  /// Save buyer bank account via Edge Function
  static Future<void> saveBankAccount({
    required String buyerId,
    required String bankName,
    required String bankCode,
    required String accountNumber,
    required String accountName,
  }) async {
    try {
      await _client.functions.invoke(
        'buyer-bank-account',
        headers: _headers,
        body: {
          'action': 'save',
          'buyer_id': buyerId,
          'bank_name': bankName,
          'bank_code': bankCode,
          'account_number': accountNumber,
          'account_name': accountName,
        },
      ).timeout(_timeout);
    } catch (e) {
      throw Exception(friendlyError(e, fallback: "We couldn't save your bank account. Please try again."));
    }
  }

  /// Get buyer bank account via Edge Function
  static Future<Map<String, dynamic>?> getBankAccount(String buyerId) async {
    try {
      final response = await _client.functions.invoke(
        'buyer-bank-account',
        headers: _headers,
        body: {
          'action': 'get',
          'buyer_id': buyerId,
        },
      ).timeout(_timeout);
      final data = response.data;
      return data is Map ? data['bank'] as Map<String, dynamic>? : null;
    } catch (e) {
      print('[CreditService] getBankAccount error: $e');
      return null;
    }
  }
}
