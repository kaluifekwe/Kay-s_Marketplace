import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import 'api_service.dart';

class AuthService {
  static const String _tokenKey = 'auth_token';
  static const String _userKey = 'auth_user';
  static const String _emailKey = 'auth_email';
  static const String _passwordKey = 'auth_password';
  static const String _userTypeKey = 'auth_user_type';
  static const String _nameKey = 'auth_name';

  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    ApiService.setToken(token);
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<void> saveUser(AppUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, user.toJson().toString());
    await prefs.setString(_userTypeKey, user.userType);
  }

  static Future<void> clearAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
    await prefs.remove(_emailKey);
    await prefs.remove(_passwordKey);
    await prefs.remove(_userTypeKey);
    await prefs.remove(_nameKey);
  }

  static Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null;
  }

  static Future<String?> getUserType() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_userTypeKey);
  }

  static Future<void> register({
    required String email,
    required String password,
    required String name,
    required String userType,
    String? shopName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, email);
    await prefs.setString(_passwordKey, password);
    await prefs.setString(_nameKey, name);

    final user = AppUser(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      phone: '',
      name: name,
      userType: userType,
      shopName: shopName,
    );
    await saveUser(user);
    await saveToken('mock_token_${DateTime.now().millisecondsSinceEpoch}');
  }

  static Future<bool> login(String email, String password) async {
    final prefs = await SharedPreferences.getInstance();
    final savedEmail = prefs.getString(_emailKey);
    final savedPassword = prefs.getString(_passwordKey);
    if (savedEmail == null || savedPassword == null) return false;
    return savedEmail == email && savedPassword == password;
  }

  static Future<void> sendOtp(String phone) async {
    await ApiService.post('/auth/send-otp', {'phone': phone});
  }

  static Future<Map<String, dynamic>> verifyOtp(String phone, String otp) async {
    final response = await ApiService.post('/auth/verify-otp', {
      'phone': phone,
      'otp': otp,
    });
    if (response['token'] != null) {
      await saveToken(response['token']);
      final user = AppUser.fromJson(response['user']);
      await saveUser(user);
    }
    return response;
  }
}