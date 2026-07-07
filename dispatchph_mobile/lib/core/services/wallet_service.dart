import 'package:supabase_flutter/supabase_flutter.dart';

/// Read/write access to the user's wallet. Balance mutations happen ONLY
/// server-side (Edge Functions + the wallet_credit/wallet_debit RPCs); this
/// service just reads balances/history and invokes the money-moving Edge
/// Functions. Mirrors CreditService/PaymentService.
/// Thrown by [WalletService.createVirtualAccount] when there's no verified NIN
/// on file, so the buyer must supply a BVN instead.
class WalletBvnRequired implements Exception {
  final String message;
  WalletBvnRequired(this.message);
  @override
  String toString() => message;
}

class WalletService {
  static final _client = Supabase.instance.client;

  // Money operations must fail fast on a stalled connection (see PaymentService).
  static const _timeout = Duration(seconds: 20);

  static Map<String, String> get _headers {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final session = _client.auth.currentSession;
    if (session != null && session.accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${session.accessToken}';
    }
    return headers;
  }

  /// Create (or fetch) the buyer's permanent Flutterwave virtual account.
  /// Flutterwave needs the customer's NIN or BVN for a static NGN account; the
  /// server prefers the NIN already verified during KYC, so [bvn] is only needed
  /// as a fallback when no verified NIN exists. Identity data is passed through
  /// server-side and never stored. Returns { account_number, bank_name }.
  ///
  /// Throws [WalletBvnRequired] when the server has no NIN on file and a BVN
  /// must be supplied.
  static Future<Map<String, dynamic>> createVirtualAccount({String? bvn}) async {
    final response = await _client.functions.invoke(
      'create-virtual-account',
      headers: _headers,
      body: bvn != null ? {'bvn': bvn} : {},
    ).timeout(_timeout);

    final data = response.data;
    if (response.status != 200) {
      final err = data is Map ? data['error'] : null;
      if (err == 'identity_required' || (data is Map && data['need_bvn'] == true)) {
        throw WalletBvnRequired(
          data is Map ? (data['message'] as String? ?? 'Enter your BVN to continue.') : 'Enter your BVN to continue.',
        );
      }
      throw Exception(data is Map ? (data['message'] ?? err ?? 'Could not create funding account') : 'Could not create funding account');
    }
    return data as Map<String, dynamic>;
  }

  /// The wallet row, or null if it hasn't been created yet (created lazily on
  /// first credit / virtual-account setup).
  static Future<Map<String, dynamic>?> getWallet(String userId) async {
    try {
      return await _client
          .from('wallets')
          .select('user_id, balance, currency, status, flw_va_number, flw_va_bank')
          .eq('user_id', userId)
          .maybeSingle();
    } catch (e) {
      print('[WalletService] getWallet error: $e');
      return null;
    }
  }

  /// Spendable balance (0 when no wallet row exists yet).
  static Future<double> getBalance(String userId) async {
    final wallet = await getWallet(userId);
    return (wallet?['balance'] as num?)?.toDouble() ?? 0;
  }

  /// Ledger history, newest first.
  static Future<List<Map<String, dynamic>>> getTransactions(String userId) async {
    try {
      final data = await _client
          .from('wallet_transactions')
          .select('id, amount, balance_after, type, status, description, order_id, created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(50);
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      print('[WalletService] getTransactions error: $e');
      return [];
    }
  }
}
