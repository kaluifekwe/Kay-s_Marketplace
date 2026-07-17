import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/models.dart';
import 'supabase_service.dart';
import 'error_text.dart';

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

  /// Register a new account. Returns null on success, or a clear, user-facing
  /// error message (never a raw code) on failure.
  static Future<String?> register({
    String? id,
    required String email,
    required String password,
    required String name,
    required String role,
    String? phone,
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

      if (response.user == null) {
        return 'That email may already be registered. Try logging in instead.';
      }

      final userId = response.user!.id;
      final uniqueId = await _generateUniqueId();

      final userData = <String, dynamic>{
        'id': userId,
        'email': email,
        'name': name,
        'role': role,
        'password': 'managed_by_supabase_auth',
      };
      // Contact phone — the number couriers call for pickup/delivery. Without it
      // a booking would fall back to a placeholder and the rider couldn't reach
      // the user, so it's captured at signup.
      if (phone != null && phone.trim().isNotEmpty) {
        userData['phone'] = phone.trim();
      }
      if (address != null && address.isNotEmpty) {
        userData['address'] = address;
      }
      if (state != null && state.isNotEmpty) {
        userData['state'] = state;
      }
      if (lga != null && lga.isNotEmpty) {
        userData['lga'] = lga;
      }

      // UPSERT, not insert: the on_auth_user_created trigger (atomic_signup.sql)
      // already created this row inside signUp()'s transaction, so an insert
      // would fail on the id and report failure for a signup that worked. The
      // trigger guarantees the profile EXISTS (no more orphaned auth users);
      // this call enriches it with the fields only the client knows —
      // phone/address/state/lga/unique_id.
      try {
        userData['unique_id'] = uniqueId;
        await SupabaseService.client.from('users').upsert(userData);
      } catch (_) {
        // unique_id collision or an address the column rejects: retry without
        // them rather than lose the whole profile.
        userData.remove('unique_id');
        userData.remove('address');
        await SupabaseService.client.from('users').upsert(userData);
      }

      // ₦200 welcome credit for new buyers is granted SERVER-SIDE by the
      // grant_welcome_credit trigger on users (secure_credit.sql) — the client
      // can no longer mint credit, so there's nothing to do here.

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('auth_user_id', userId);
      await prefs.setString('auth_email', email);
      await prefs.setString('auth_name', name);
      await prefs.setString('auth_role', role);
      await prefs.setString('auth_store_id', '');
      await prefs.setString('auth_unique_id', uniqueId);

      return null;
    } catch (e) {
      print('[AuthService] Register error: $e');
      return friendlyAuthError(e, fallback: "We couldn't create your account. Please try again.");
    }
  }

  /// Whether the signed-in user has verified their email (OTP). Existing/legacy
  /// users (null column) are grandfathered as verified. Fails OPEN (returns true)
  /// on any error so a transient hiccup never locks out a legitimate user.
  static Future<bool> isEmailVerified() async {
    try {
      final uid = SupabaseService.auth.currentUser?.id;
      if (uid == null) return true;
      final row = await SupabaseService.client
          .from('users')
          .select('email_verified')
          .eq('id', uid)
          .maybeSingle();
      if (row == null) return true;
      return row['email_verified'] != false; // null or true => verified
    } catch (_) {
      return true;
    }
  }

  static ({bool ok, String? error}) _fnResult(dynamic data, int? status, {required String fallback}) {
    final msg = data is Map ? (data['message'] ?? data['error']) : null;
    return (ok: false, error: (msg ?? (status != null ? '$fallback ($status).' : fallback)).toString());
  }

  /// Password reset step 1 — email a 6-digit code (logged-out flow). Returns
  /// null on success, else a user-facing message.
  static Future<String?> requestPasswordReset(String email) async {
    try {
      final res = await SupabaseService.client.functions
          .invoke('request-password-reset', body: {'email': email.trim()});
      if (res.status == 200) return null;
      return _fnResult(res.data, res.status, fallback: "We couldn't send the reset code. Please try again.").error;
    } on FunctionException catch (e) {
      return _fnResult(e.details, e.status, fallback: "We couldn't send the reset code").error;
    } catch (_) {
      return 'Could not reach the server. Check your connection and try again.';
    }
  }

  /// Password reset step 2 — verify the code and set a new password. Returns
  /// null on success, else a user-facing message.
  static Future<String?> confirmPasswordReset({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    try {
      final res = await SupabaseService.client.functions.invoke(
        'confirm-password-reset',
        body: {'email': email.trim(), 'code': code.trim(), 'new_password': newPassword},
      );
      if (res.status == 200) return null;
      return _fnResult(res.data, res.status, fallback: 'Could not reset your password. Please try again.').error;
    } on FunctionException catch (e) {
      return _fnResult(e.details, e.status, fallback: 'Could not reset your password').error;
    } catch (_) {
      return 'Could not reach the server. Check your connection and try again.';
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
      return friendlyAuthError(e, fallback: "We couldn't sign you in. Please try again.");
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

  /// Current name + contact phone for the edit-profile screen.
  static Future<Map<String, String>> loadProfile() async {
    try {
      final userId = await getUserId();
      if (userId.isEmpty) return {'name': '', 'phone': ''};
      final data = await SupabaseService.client
          .from('users')
          .select('name, phone')
          .eq('id', userId)
          .maybeSingle();
      return {
        'name': (data?['name'] as String?) ?? '',
        'phone': (data?['phone'] as String?) ?? '',
      };
    } catch (e) {
      print('[AuthService] loadProfile error: $e');
      return {'name': '', 'phone': ''};
    }
  }

  /// Save edited name + contact phone. Returns null on success, else a message.
  static Future<String?> updateProfile({required String name, required String phone}) async {
    try {
      final userId = await getUserId();
      if (userId.isEmpty) return 'You are not signed in.';
      await SupabaseService.client.from('users').update({
        'name': name.trim(),
        'phone': phone.trim(),
      }).eq('id', userId);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('auth_name', name.trim());
      return null;
    } catch (e) {
      print('[AuthService] updateProfile error: $e');
      return 'Could not save your changes. Please try again.';
    }
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
