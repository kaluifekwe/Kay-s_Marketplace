import 'package:supabase_flutter/supabase_flutter.dart';

/// Read/write access to the user's wallet. Balance mutations happen ONLY
/// server-side (Edge Functions + the wallet_credit/wallet_debit RPCs); this
/// service just reads balances/history and invokes the money-moving Edge
/// Functions. Mirrors CreditService/PaymentService.
class WalletService {
  static final _client = Supabase.instance.client;

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
