import 'package:flutter_bloc/flutter_bloc.dart';
import '../services/supabase_service.dart';
import '../models/models.dart';

class NotificationCubit extends Cubit<NotificationState> {
  NotificationCubit() : super(NotificationState());

  Future<void> loadNotifications(String userId) async {
    try {
      final data = await SupabaseService.client
          .from('notifications')
          .select('id, user_id, title, body, type, reference_id, is_read, created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(100);

      final notifications = (data as List)
          .map((n) => AppNotification.fromJson(n))
          .toList();
      final unreadCount = notifications.where((n) => !n.isRead).length;

      emit(state.copyWith(
        notifications: notifications,
        unreadCount: unreadCount,
        isLoading: false,
      ));
    } catch (e) {
      emit(state.copyWith(isLoading: false));
    }
  }

  Future<void> markAsRead(String notificationId) async {
    try {
      await SupabaseService.client
          .from('notifications')
          .update({'is_read': true}).eq('id', notificationId);

      final updated = state.notifications.map((n) {
        if (n.id == notificationId && !n.isRead) {
          return AppNotification(
            id: n.id,
            userId: n.userId,
            title: n.title,
            body: n.body,
            type: n.type,
            referenceId: n.referenceId,
            isRead: true,
            createdAt: n.createdAt,
          );
        }
        return n;
      }).toList();

      final unreadCount = updated.where((n) => !n.isRead).length;
      emit(state.copyWith(notifications: updated, unreadCount: unreadCount));
    } catch (e) {
      // silent
    }
  }

  Future<void> markAllAsRead(String userId) async {
    try {
      await SupabaseService.client
          .from('notifications')
          .update({'is_read': true})
          .eq('user_id', userId)
          .eq('is_read', false);

      final updated = state.notifications.map((n) {
        if (!n.isRead) {
          return AppNotification(
            id: n.id,
            userId: n.userId,
            title: n.title,
            body: n.body,
            type: n.type,
            referenceId: n.referenceId,
            isRead: true,
            createdAt: n.createdAt,
          );
        }
        return n;
      }).toList();

      emit(state.copyWith(notifications: updated, unreadCount: 0));
    } catch (e) {
      // silent
    }
  }

  Future<void> deleteNotification(String notificationId) async {
    try {
      await SupabaseService.client
          .from('notifications')
          .delete()
          .eq('id', notificationId);

      final updated = state.notifications.where((n) => n.id != notificationId).toList();
      final unreadCount = updated.where((n) => !n.isRead).length;
      emit(state.copyWith(notifications: updated, unreadCount: unreadCount));
    } catch (e) {
      // silent
    }
  }

  Future<void> deleteAllNotifications(String userId) async {
    try {
      await SupabaseService.client
          .from('notifications')
          .delete()
          .eq('user_id', userId);

      emit(state.copyWith(notifications: [], unreadCount: 0));
    } catch (e) {
      // silent
    }
  }

  /// Create a notification — called from blocs when events happen
  static Future<void> create({
    required String userId,
    required String title,
    required String body,
    String type = 'general',
    String? referenceId,
  }) async {
    try {
      await SupabaseService.client.from('notifications').insert({
        'user_id': userId,
        'title': title,
        'body': body,
        'type': type,
        'reference_id': referenceId,
      });
    } catch (e) {
      print('[NotificationCubit] create error: $e');
    }
  }
}

class NotificationState {
  final List<AppNotification> notifications;
  final int unreadCount;
  final bool isLoading;

  NotificationState({
    this.notifications = const [],
    this.unreadCount = 0,
    this.isLoading = true,
  });

  NotificationState copyWith({
    List<AppNotification>? notifications,
    int? unreadCount,
    bool? isLoading,
  }) {
    return NotificationState(
      notifications: notifications ?? this.notifications,
      unreadCount: unreadCount ?? this.unreadCount,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}
