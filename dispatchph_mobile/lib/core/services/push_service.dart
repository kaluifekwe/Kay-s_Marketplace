import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PushService {
  static Future<void> sendPush({
    required String userId,
    required String title,
    required String body,
    Map<String, String>? data,
  }) async {
    try {
      await Supabase.instance.client.functions.invoke(
        'send-push',
        body: jsonEncode({
          'user_id': userId,
          'title': title,
          'body': body,
          'data': data ?? {},
        }),
      );

      if (kDebugMode) {
        print('[Push] Sent to $userId: $title');
      }
    } catch (e) {
      if (kDebugMode) {
        print('[Push] Error sending: $e');
      }
    }
  }
}
