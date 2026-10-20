import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'notification_service.dart';
import 'supabase_service.dart';
import 'auth_service.dart';

class FCMService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static String? _currentToken;

  static String? get currentToken => _currentToken;

  static Future<void> init() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    if (kDebugMode) {
      print('[FCM] Permission: ${settings.authorizationStatus}');
    }

    _currentToken = await _messaging.getToken();
    if (kDebugMode) {
      print('[FCM] Token: $_currentToken');
    }

    if (_currentToken != null) {
      await _saveToken(_currentToken!);
    }

    _messaging.onTokenRefresh.listen((token) {
      _currentToken = token;
      _saveToken(token);
    });

    FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpenedApp);

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      _onMessageOpenedApp(initialMessage);
    }
  }

  static Future<void> _saveToken(String token) async {
    try {
      final userId = await AuthService.getUserId();
      if (userId.isEmpty) return;

      final platform = defaultTargetPlatform == TargetPlatform.android ? 'android' : 'ios';

      await SupabaseService.client.from('device_tokens').upsert(
        {
          'user_id': userId,
          'fcm_token': token,
          'platform': platform,
        },
        onConflict: 'user_id,platform',
      );

      if (kDebugMode) {
        print('[FCM] Token saved for user $userId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('[FCM] Error saving token: $e');
      }
    }
  }

  static Future<void> deleteToken() async {
    try {
      final userId = await AuthService.getUserId();
      if (userId.isEmpty) return;

      await SupabaseService.client
          .from('device_tokens')
          .delete()
          .eq('user_id', userId);

      await _messaging.deleteToken();
      _currentToken = null;

      if (kDebugMode) {
        print('[FCM] Token deleted');
      }
    } catch (e) {
      if (kDebugMode) {
        print('[FCM] Error deleting token: $e');
      }
    }
  }

  static void _onForegroundMessage(RemoteMessage message) {
    if (kDebugMode) {
      print('[FCM] Foreground message: ${message.notification?.title}');
    }

    final notification = message.notification;
    if (notification == null) return;

    final data = message.data;
    final type = data['type'] ?? 'generic';

    switch (type) {
      case 'order':
        NotificationService.showOrderNotification(
          title: notification.title ?? 'Order Update',
          body: notification.body ?? '',
        );
        break;
      case 'chat':
        NotificationService.showChatNotification(
          title: notification.title ?? 'New Message',
          body: notification.body ?? '',
        );
        break;
      case 'dispute':
        NotificationService.showDisputeNotification(
          title: notification.title ?? 'Dispute Update',
          body: notification.body ?? '',
        );
        break;
      default:
        NotificationService.showGenericNotification(
          title: notification.title ?? "Kay's Market",
          body: notification.body ?? '',
        );
    }
  }

  static void _onMessageOpenedApp(RemoteMessage message) {
    if (kDebugMode) {
      print('[FCM] Message opened app: ${message.data}');
    }
  }

  @pragma('vm:entry-point')
  static Future<void> backgroundHandler(RemoteMessage message) async {
    if (kDebugMode) {
      print('[FCM] Background message: ${message.notification?.title}');
    }
  }
}
