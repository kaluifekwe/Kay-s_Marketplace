import 'package:flutter_bloc/flutter_bloc.dart';
import '../services/wallet_service.dart';

class WalletCubit extends Cubit<WalletState> {
  WalletCubit() : super(WalletState());

  Future<void> load(String userId) async {
    if (userId.isEmpty) return;
    try {
      final wallet = await WalletService.getWallet(userId);
      final history = await WalletService.getTransactions(userId);
      emit(state.copyWith(
        balance: (wallet?['balance'] as num?)?.toDouble() ?? 0,
        vaNumber: wallet?['flw_va_number'] as String?,
        vaBank: wallet?['flw_va_bank'] as String?,
        status: wallet?['status'] as String? ?? 'active',
        transactions: history,
        isLoading: false,
      ));
    } catch (e) {
      emit(state.copyWith(isLoading: false));
    }
  }
}

class WalletState {
  final double balance;
  final String? vaNumber;
  final String? vaBank;
  final String status;
  final List<Map<String, dynamic>> transactions;
  final bool isLoading;

  WalletState({
    this.balance = 0,
    this.vaNumber,
    this.vaBank,
    this.status = 'active',
    this.transactions = const [],
    this.isLoading = true,
  });

  WalletState copyWith({
    double? balance,
    String? vaNumber,
    String? vaBank,
    String? status,
    List<Map<String, dynamic>>? transactions,
    bool? isLoading,
  }) {
    return WalletState(
      balance: balance ?? this.balance,
      vaNumber: vaNumber ?? this.vaNumber,
      vaBank: vaBank ?? this.vaBank,
      status: status ?? this.status,
      transactions: transactions ?? this.transactions,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}
