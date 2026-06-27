import 'package:flutter_bloc/flutter_bloc.dart';
import '../services/auth_service.dart';
import '../services/fcm_service.dart';

class AuthCubit extends Cubit<AuthState> {
  AuthCubit() : super(AuthState.uninitialized());

  Future<void> checkAuth() async {
    final loggedIn = await AuthService.isLoggedIn();
    if (loggedIn) {
      final role = await AuthService.getRole();
      emit(AuthState.authenticated(role: role));
      FCMService.init();
    } else {
      emit(AuthState.unauthenticated());
    }
  }

  Future<void> login(String email, String password) async {
    final error = await AuthService.login(email, password);
    if (error == null) {
      final role = await AuthService.getRole();
      emit(AuthState.authenticated(role: role));
      FCMService.init();
    }
  }

  Future<void> register({
    required String email,
    required String password,
    required String name,
    required String role,
  }) async {
    final success = await AuthService.register(
      email: email,
      password: password,
      name: name,
      role: role,
    );
    if (success) {
      emit(AuthState.authenticated(role: role));
      FCMService.init();
    }
  }

  Future<void> logout() async {
    FCMService.deleteToken();
    await AuthService.logout();
    emit(AuthState.unauthenticated());
  }
}

class AuthState {
  final bool isAuthenticated;
  final String? role;

  const AuthState._({required this.isAuthenticated, this.role});

  factory AuthState.uninitialized() => const AuthState._(isAuthenticated: false);
  factory AuthState.unauthenticated() => const AuthState._(isAuthenticated: false);
  factory AuthState.authenticated({required String role}) =>
      AuthState._(isAuthenticated: true, role: role);
}
