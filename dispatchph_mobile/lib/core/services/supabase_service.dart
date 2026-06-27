import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  static SupabaseClient? _client;

  static SupabaseClient get client {
    if (_client == null) {
      throw Exception('Supabase not initialized. Call SupabaseService.init() first.');
    }
    return _client!;
  }

  static Future<void> init() async {
    _client = Supabase.instance.client;
  }

  static GoTrueClient get auth => client.auth;
}
