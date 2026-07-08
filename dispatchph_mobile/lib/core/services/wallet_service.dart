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

/// Thrown by [WalletService.checkout] when the wallet balance is too low —
/// carries the shortfall so the UI can prompt the buyer to Add money.
class WalletInsufficient implements Exception {
  final double balance;
  final double required;
  final double shortfall;
  WalletInsufficient({required this.balance, required this.required, required this.shortfall});
  @override
  String toString() => 'Insufficient wallet balance';
}

/// Thrown by [WalletService.requestWithdrawal] when there's no bank account on
/// file to pay out to.
class WalletNoBankAccount implements Exception {
  @override
  String toString() => 'No bank account on file';
}

/// Thrown by [WalletService.requestWithdrawal] when the withdrawal PIN is wrong,
/// locked, missing, or malformed — carries a user-facing message.
class WalletPinError implements Exception {
  final String message;
  WalletPinError(this.message);
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

  /// Pay for the cart entirely from the wallet. Returns the created orders.
  /// Throws [WalletInsufficient] (with the shortfall) when the balance is too low.
  static Future<Map<String, dynamic>> checkout({
    required String buyerId,
    required List<Map<String, dynamic>> vendorOrders,
  }) async {
    final response = await _client.functions.invoke(
      'wallet-checkout',
      headers: _headers,
      body: {'buyer_id': buyerId, 'vendor_orders': vendorOrders},
    ).timeout(_timeout);

    final data = response.data;
    if (response.status != 200) {
      if (data is Map && data['error'] == 'insufficient_balance') {
        throw WalletInsufficient(
          balance: (data['balance'] as num?)?.toDouble() ?? 0,
          required: (data['required'] as num?)?.toDouble() ?? 0,
          shortfall: (data['shortfall'] as num?)?.toDouble() ?? 0,
        );
      }
      throw Exception(data is Map ? (data['message'] ?? data['error'] ?? 'Checkout failed') : 'Checkout failed');
    }
    return data as Map<String, dynamic>;
  }

  /// How much the user may withdraw right now (vendor = full balance; buyer =
  /// refunded money only).
  static Future<double> getWithdrawable(String userId) async {
    try {
      final data = await _client.rpc('wallet_withdrawable', params: {'p_user_id': userId});
      return (data as num?)?.toDouble() ?? 0;
    } catch (e) {
      print('[WalletService] getWithdrawable error: $e');
      return 0;
    }
  }

  /// Whether the user has a withdrawal PIN set, and whether it's locked after
  /// too many wrong attempts.
  static Future<({bool hasPin, bool locked})> getWithdrawalPinStatus() async {
    final response = await _client.functions.invoke(
      'withdrawal-pin',
      headers: _headers,
      body: {'action': 'status'},
    ).timeout(_timeout);
    final data = response.data;
    return (hasPin: data is Map && data['has_pin'] == true, locked: data is Map && data['locked'] == true);
  }

  /// Create the user's 4-digit withdrawal PIN (first time only).
  static Future<void> setWithdrawalPin(String pin) async {
    try {
      await _client.functions.invoke(
        'withdrawal-pin',
        headers: _headers,
        body: {'action': 'set', 'pin': pin},
      ).timeout(_timeout);
    } on FunctionException catch (e) {
      final d = e.details;
      throw Exception(d is Map ? (d['message'] ?? d['error'] ?? 'Could not set PIN') : 'Could not set PIN');
    }
  }

  /// Request a withdrawal to the user's saved bank account. Returns immediately
  /// with a 'processing' status; the transfer webhook confirms or reverses.
  /// Requires the 4-digit withdrawal [pin]. Throws [WalletNoBankAccount] when no
  /// bank account is on file, or [WalletPinError] on a PIN problem.
  static Future<Map<String, dynamic>> requestWithdrawal({
    required double amount,
    required String pin,
  }) async {
    try {
      final response = await _client.functions.invoke(
        'wallet-withdraw',
        headers: _headers,
        body: {'amount': amount, 'pin': pin},
      ).timeout(_timeout);
      return (response.data as Map).cast<String, dynamic>();
    } on FunctionException catch (e) {
      // invoke() throws on non-2xx — inspect the function's error payload.
      final data = e.details;
      final err = data is Map ? data['error'] : null;
      final msg = data is Map ? (data['message'] ?? err) : null;
      if (err == 'no_bank_account') throw WalletNoBankAccount();
      if (err == 'pin_wrong' || err == 'pin_locked' || err == 'pin_not_set' || err == 'pin_invalid') {
        throw WalletPinError(msg?.toString() ?? 'PIN error');
      }
      throw Exception(msg?.toString() ?? 'Withdrawal failed');
    }
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
