import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import 'supabase_service.dart';

class AuthService {
  static Future<String> _generateUniqueId() async {
    final random = DateTime.now().millisecondsSinceEpoch % 10000;
    final id = random.toString().padLeft(4, '0');
    final existing = await SupabaseService.client
        .from('users')
        .select('id')
        .eq('unique_id', id)
        .maybeSingle();
    if (existing != null) {
      return _generateUniqueId();
    }
    return id;
  }

  static Future<bool> register({
    String? id,
    required String email,
    required String password,
    required String name,
    required String role,
    String? storeId,
    String? address,
    String? state,
    String? lga,
  }) async {
    try {
      final response = await SupabaseService.auth.signUp(
        email: email,
        password: password,
        data: {'name': name, 'role': role},
      );

      if (response.user == null) return false;

      final userId = response.user!.id;
      final uniqueId = await _generateUniqueId();

      final userData = <String, dynamic>{
        'id': userId,
        'email': email,
        'name': name,
        'role': role,
        'password': 'managed_by_supabase_auth',
      };
      if (address != null && address.isNotEmpty) {
        userData['address'] = address;
      }
      if (state != null && state.isNotEmpty) {
        userData['state'] = state;
      }
      if (lga != null && lga.isNotEmpty) {
        userData['lga'] = lga;
      }

      try {
        userData['unique_id'] = uniqueId;
        await SupabaseService.client.from('users').insert(userData);
      } catch (_) {
        userData.remove('unique_id');
        userData.remove('address');
        await SupabaseService.client.from('users').insert(userData);
      }

      // ₦200 welcome credit for new buyers (not vendors). Failure here
      // should never block account creation, so it's isolated in its own
      // try/catch.
      if (role == 'buyer') {
        try {
          await SupabaseService.client.rpc('increment_kays_credit', params: {
            'p_user_id': userId,
            'p_amount': 200,
          });
          final expiresAt = DateTime.now().add(const Duration(days: 90));
          await SupabaseService.client.from('credit_transactions').insert({
            'buyer_id': userId,
            'amount': 200,
            'type': 'cashback',
            'description': '₦200 welcome bonus',
            'expires_at': expiresAt.toIso8601String(),
          });
        } catch (e) {
          print('[AuthService] welcome credit error: $e');
        }
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('auth_user_id', userId);
      await prefs.setString('auth_email', email);
      await prefs.setString('auth_name', name);
      await prefs.setString('auth_role', role);
      await prefs.setString('auth_store_id', '');
      await prefs.setString('auth_unique_id', uniqueId);

      return true;
    } catch (e) {
      print('[AuthService] Register error: $e');
      return false;
    }
  }

  static Future<String?> login(String email, String password) async {
    try {
      final response = await SupabaseService.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (response.user == null) return 'Login failed. No user returned.';

      final userId = response.user!.id;

      Map<String, dynamic>? userData;
      try {
        userData = await SupabaseService.client
            .from('users')
            .select('id, email, name, role, store_id, unique_id, address')
            .eq('id', userId)
            .maybeSingle();
      } catch (_) {
        userData = await SupabaseService.client
            .from('users')
            .select('id, email, name, role, store_id')
            .eq('id', userId)
            .maybeSingle();
      }

      if (userData == null) {
        final uniqueId = await _generateUniqueId();
        final insertData = <String, dynamic>{
          'id': userId,
          'email': email,
          'name': response.user!.userMetadata?['name'] ?? email,
          'role': response.user!.userMetadata?['role'] ?? 'buyer',
          'password': 'managed_by_supabase_auth',
        };
        try {
          insertData['unique_id'] = uniqueId;
          await SupabaseService.client.from('users').insert(insertData);
        } catch (_) {
          insertData.remove('unique_id');
          await SupabaseService.client.from('users').insert(insertData);
        }
      }

      Map<String, dynamic> user;
      try {
        user = await SupabaseService.client
            .from('users')
            .select('id, email, name, role, store_id, unique_id, address')
            .eq('id', userId)
            .single();
      } catch (_) {
        user = await SupabaseService.client
            .from('users')
            .select('id, email, name, role, store_id')
            .eq('id', userId)
            .single();
      }

      final role = user['role'] as String;
      final name = user['name'] as String;
      final storeId = user['store_id'] as String? ?? '';
      final uniqueId = user['unique_id'] as String? ?? '';
      final address = user['address'] as String? ?? '';

      if (role == 'vendor' && storeId.isNotEmpty) {
        final store = await SupabaseService.client
            .from('stores')
            .select('id, vendor_id')
            .eq('id', storeId)
            .maybeSingle();

        if (store != null && store['vendor_id'] != userId) {
          await SupabaseService.client
              .from('stores')
              .update({'vendor_id': userId}).eq('id', storeId);

          await SupabaseService.client
              .from('chats')
              .update({'vendor_id': userId})
              .eq('vendor_id', store['vendor_id']);

          await SupabaseService.client
              .from('orders')
              .update({'vendor_id': userId})
              .eq('vendor_id', store['vendor_id']);
        }
      }

      await SupabaseService.client
          .from('users')
          .update({'last_active': DateTime.now().toIso8601String()})
          .eq('id', userId);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('auth_user_id', userId);
      await prefs.setString('auth_email', email);
      await prefs.setString('auth_name', name);
      await prefs.setString('auth_role', role);
      await prefs.setString('auth_store_id', storeId);
      await prefs.setString('auth_unique_id', uniqueId);
      await prefs.setString('auth_address', address);

      return null;
    } catch (e) {
      print('[AuthService] Login error: $e');
      final msg = e.toString();
      if (msg.contains('Email not confirmed') || msg.contains('email_not_confirmed')) {
        return 'Email not confirmed. Please check your inbox and confirm your email first.';
      }
      if (msg.contains('Invalid login credentials') || msg.contains('invalid_grant')) {
        return 'Invalid email or password.';
      }
      if (msg.contains('SocketException') || msg.contains('Failed host lookup')) {
        return 'No internet connection. Please check your network.';
      }
      return 'Login failed: ${e.toString()}';
    }
  }

  static Future<bool> isLoggedIn() async {
    final session = SupabaseService.auth.currentSession;
    if (session != null) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('auth_user_id');
  }

  static Future<String> getRole() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_role') ?? 'buyer';
  }

  static Future<String> getUserId() async {
    final user = SupabaseService.auth.currentUser;
    if (user != null) return user.id;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_user_id') ?? '';
  }

  static Future<String> getUserName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_name') ?? '';
  }

  static Future<String> getStoreId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_store_id') ?? '';
  }

  static Future<void> updateLastActive() async {
    final userId = await getUserId();
    if (userId.isNotEmpty) {
      try {
        await SupabaseService.client
            .from('users')
            .update({'last_active': DateTime.now().toIso8601String()})
            .eq('id', userId);
      } catch (e) {
        print('[AuthService] updateLastActive error: $e');
      }
    }
  }

  static Future<Map<String, dynamic>?> getUserProfile(String userId) async {
    try {
      return await SupabaseService.client
          .from('users')
          .select('id, email, name, role, store_id, phone, last_active')
          .eq('id', userId)
          .maybeSingle();
    } catch (e) {
      return null;
    }
  }

  static bool isOnline(dynamic user) {
    if (user == null) return false;
    final lastActive = user is AppUser ? user.lastActive : (user is Map<String, dynamic> ? user['last_active'] : null);
    if (lastActive == null) return false;
    final parsed = lastActive is DateTime ? lastActive : DateTime.parse(lastActive as String);
    return DateTime.now().difference(parsed).inMinutes < 5;
  }

  static Future<void> clearAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  static Future<void> logout() async {
    try {
      await SupabaseService.auth.signOut();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}
