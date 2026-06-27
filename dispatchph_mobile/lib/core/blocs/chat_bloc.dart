import 'dart:async';
import 'dart:convert';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';
import '../services/escrow_service.dart';
import '../services/notification_service.dart';
import '../services/push_service.dart';
import '../models/models.dart';
import 'notification_bloc.dart';

const _messagesPageSize = 50;

class ChatCubit extends Cubit<ChatState> {
  final EscrowService _escrow;
  RealtimeChannel? _messagesChannel;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;

  ChatCubit(this._escrow) : super(ChatState());
  EscrowService get escrow => _escrow;

  // ── Phase 2: Batch queries for chat list (2 queries instead of 1+2N) ──

  Future<void> loadChatsForBuyer(String buyerId) async {
    final sw = Stopwatch()..start();
    try {
      final data = await SupabaseService.client
          .from('chats')
          .select('id, order_id, buyer_id, vendor_id, created_at')
          .eq('buyer_id', buyerId);

      final chats = (data as List).map((c) => Chat.fromJson(c)).toList();
      if (chats.isEmpty) {
        emit(state.copyWith(chats: []));
        return;
      }

      final chatIds = chats.map((c) => c.id).toList();

      // Phase 2: Single batch query for ALL messages across all chats
      final allMsgData = await SupabaseService.client
          .from('messages')
          .select('id, chat_id, sender_id, sender_role, content, type, created_at, read_at')
          .inFilter('chat_id', chatIds)
          .order('created_at', ascending: false);

      final allMessages = (allMsgData as List)
          .map((m) => Message.fromJson(m))
          .toList();

      // Compute unread counts in Dart
      final unreadCounts = <String, int>{};
      for (final msg in allMessages) {
        if (msg.senderId != buyerId && msg.readAt == null) {
          unreadCounts[msg.chatId] = (unreadCounts[msg.chatId] ?? 0) + 1;
        }
      }

      // Compute last messages in Dart (already sorted desc, take first per chat)
      final lastMessages = <String, Message>{};
      final seenChatIds = <String>{};
      for (final msg in allMessages) {
        if (seenChatIds.add(msg.chatId)) {
          lastMessages[msg.chatId] = msg;
        }
      }

      final sorted = _sortChats(chats, unreadCounts, lastMessages);
      sw.stop();
      print('[ChatCubit] Found ${chats.length} chats for buyer [${sw.elapsedMilliseconds}ms]');
      emit(state.copyWith(chats: sorted, unreadCounts: unreadCounts, lastMessages: lastMessages));
    } catch (e) {
      print('[ChatCubit] loadChatsForBuyer error: $e');
      emit(state.copyWith(chats: []));
    }
  }

  Future<void> loadChatsForVendor(String vendorId) async {
    final sw = Stopwatch()..start();
    try {
      final data = await SupabaseService.client
          .from('chats')
          .select('id, order_id, buyer_id, vendor_id, created_at')
          .eq('vendor_id', vendorId);

      final chats = (data as List).map((c) => Chat.fromJson(c)).toList();
      if (chats.isEmpty) {
        emit(state.copyWith(chats: []));
        return;
      }

      final chatIds = chats.map((c) => c.id).toList();

      // Phase 2: Single batch query for ALL messages across all chats
      final allMsgData = await SupabaseService.client
          .from('messages')
          .select('id, chat_id, sender_id, sender_role, content, type, created_at, read_at')
          .inFilter('chat_id', chatIds)
          .order('created_at', ascending: false);

      final allMessages = (allMsgData as List)
          .map((m) => Message.fromJson(m))
          .toList();

      // Compute unread counts in Dart
      final unreadCounts = <String, int>{};
      for (final msg in allMessages) {
        if (msg.senderId != vendorId && msg.readAt == null) {
          unreadCounts[msg.chatId] = (unreadCounts[msg.chatId] ?? 0) + 1;
        }
      }

      // Compute last messages in Dart
      final lastMessages = <String, Message>{};
      final seenChatIds = <String>{};
      for (final msg in allMessages) {
        if (seenChatIds.add(msg.chatId)) {
          lastMessages[msg.chatId] = msg;
        }
      }

      final sorted = _sortChats(chats, unreadCounts, lastMessages);
      sw.stop();
      print('[ChatCubit] Found ${chats.length} chats for vendor [${sw.elapsedMilliseconds}ms]');
      emit(state.copyWith(chats: sorted, unreadCounts: unreadCounts, lastMessages: lastMessages));
    } catch (e) {
      print('[ChatCubit] loadChatsForVendor error: $e');
      emit(state.copyWith(chats: []));
    }
  }

  List<Chat> _sortChats(List<Chat> chats, Map<String, int> unread, Map<String, Message> lastMsgs) {
    final sorted = List<Chat>.from(chats);
    sorted.sort((a, b) {
      final aUnread = unread[a.id] ?? 0;
      final bUnread = unread[b.id] ?? 0;
      if (aUnread > 0 && bUnread == 0) return -1;
      if (aUnread == 0 && bUnread > 0) return 1;
      final aTime = lastMsgs[a.id]?.createdAt ?? a.createdAt;
      final bTime = lastMsgs[b.id]?.createdAt ?? b.createdAt;
      return bTime.compareTo(aTime);
    });
    return sorted;
  }

  // ── Phase 4: Parallelize openChat ──

  Future<void> openChat(String orderId, String buyerId, String vendorId, {String? currentUserId}) async {
    final sw = Stopwatch()..start();
    try {
      var chatData = await SupabaseService.client
          .from('chats')
          .select('id, order_id, buyer_id, vendor_id, created_at')
          .eq('order_id', orderId)
          .maybeSingle();

      // Fallback: find any existing chat between this buyer and vendor
      if (chatData == null) {
        final existingChats = await SupabaseService.client
            .from('chats')
            .select('id, order_id, buyer_id, vendor_id, created_at')
            .eq('buyer_id', buyerId)
            .eq('vendor_id', vendorId);
        if ((existingChats as List).isNotEmpty) {
          chatData = existingChats[0];
        }
      }

      if (chatData == null) {
        final chatId = _escrow.generateChatId();
        final insertResult = await SupabaseService.client.from('chats').insert({
          'id': chatId,
          'order_id': orderId,
          'buyer_id': buyerId,
          'vendor_id': vendorId,
        }).select('id').maybeSingle();

        if (insertResult == null) {
          print('[ChatCubit] Chat insert failed (RLS?), trying select again...');
        }

        chatData = await SupabaseService.client
            .from('chats')
            .select('id, order_id, buyer_id, vendor_id, created_at')
            .eq('order_id', orderId)
            .maybeSingle();

        if (chatData == null) {
          print('[ChatCubit] ERROR: Could not find or create chat for orderId=$orderId');
          return;
        }
      }

      final chat = Chat.fromJson(chatData);

      if (currentUserId != null) {
        // Phase 3: Load only last 50 messages (paginated, newest first)
        final messages = await _getMessagesByChatPaginated(chat.id, limit: _messagesPageSize);

        // Phase 4: Parallelize markChatRead + emit
        await markChatRead(chat.id, currentUserId);

        sw.stop();
        print('[ChatCubit] Loaded ${messages.length} messages [${sw.elapsedMilliseconds}ms]');
        emit(state.copyWith(
          currentChatId: chat.id,
          messages: messages.reversed.toList(),
          hasMoreMessages: messages.length >= _messagesPageSize,
        ));

        _subscribeToMessages(chat.id);
      }
    } catch (e) {
      print('[ChatCubit] openChat error: $e');
    }
  }

  // ── Phase 3: Paginated message loading ──

  Future<List<Message>> _getMessagesByChatPaginated(String chatId, {int limit = _messagesPageSize, DateTime? before}) async {
    try {
      var query = SupabaseService.client
          .from('messages')
          .select('id, chat_id, sender_id, sender_role, content, type, created_at, read_at, reply_to_id, reply_to_content, reply_to_sender, delivery_fee_amount, vendor_contribution, buyer_fee_amount, delivery_fee_status')
          .eq('chat_id', chatId)
          .lt('created_at', (before ?? DateTime.now()).toIso8601String())
          .order('created_at', ascending: false)
          .limit(limit);

      final data = await query;
      return (data as List).map((m) => Message.fromJson(m)).toList();
    } catch (e) {
      print('[ChatCubit] _getMessagesByChatPaginated error: $e');
      return [];
    }
  }

  /// Load older messages when scrolling up
  Future<void> loadMoreMessages(String chatId) async {
    if (state.messages.isEmpty || !state.hasMoreMessages) return;
    final sw = Stopwatch()..start();
    try {
      final oldest = state.messages.first.createdAt;
      final older = await _getMessagesByChatPaginated(chatId, before: oldest);
      sw.stop();
      if (older.isEmpty) {
        emit(state.copyWith(hasMoreMessages: false));
        return;
      }
      // Prepend older messages (they come in desc order, reverse to asc)
      final updated = [...older.reversed, ...state.messages];
      print('[ChatCubit] loadMoreMessages +${older.length} [${sw.elapsedMilliseconds}ms]');
      emit(state.copyWith(
        messages: updated,
        hasMoreMessages: older.length >= _messagesPageSize,
      ));
    } catch (e) {
      print('[ChatCubit] loadMoreMessages error: $e');
    }
  }

  // ── Phase 3: Optimistic send (no re-fetch) ──

  Future<void> sendMessage({
    required String chatId,
    required String senderId,
    required String senderRole,
    required String content,
    String type = 'text',
    String? replyToId,
    String? replyToContent,
    String? replyToSender,
    String? recipientId,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final result = await SupabaseService.client.from('messages').insert({
        'chat_id': chatId,
        'sender_id': senderId,
        'sender_role': senderRole,
        'content': content,
        'type': type,
        'reply_to_id': replyToId,
        'reply_to_content': replyToContent,
        'reply_to_sender': replyToSender,
      }).select('id, created_at').maybeSingle();

      if (result == null) {
        print('[ChatCubit] sendMessage FAILED - RLS blocked insert');
        return;
      }

      // Phase 3: Optimistically append the new message to state
      final optimisticMsg = Message(
        id: result['id'] as String,
        chatId: chatId,
        senderId: senderId,
        senderRole: senderRole,
        content: content,
        type: type,
        replyToId: replyToId,
        replyToContent: replyToContent,
        replyToSender: replyToSender,
        createdAt: DateTime.parse(result['created_at'] as String),
      );
      final updated = List<Message>.from(state.messages)..add(optimisticMsg);
      emit(state.copyWith(messages: updated));

      if (recipientId != null) {
        final senderDisplay = senderRole == 'buyer' ? 'Buyer' : 'Vendor';
        final notifBody = type == 'text' ? content : 'Sent a $type';
        await NotificationService.showChatNotification(title: senderDisplay, body: notifBody);

        PushService.sendPush(
          userId: recipientId,
          title: senderDisplay,
          body: notifBody,
          data: {'type': 'chat', 'chatId': chatId},
        );

        await NotificationCubit.create(
          userId: recipientId,
          title: 'New Message',
          body: '$senderDisplay: ${notifBody.length > 80 ? '${notifBody.substring(0, 80)}...' : notifBody}',
          type: 'chat',
          referenceId: chatId,
        );
      }

      sw.stop();
      print('[ChatCubit] sendMessage total=${sw.elapsedMilliseconds}ms');
    } catch (e) {
      print('[ChatCubit] sendMessage error: $e');
    }
  }

  Future<void> sendProductCard({
    required String chatId,
    required String senderId,
    required String senderRole,
    required Map<String, dynamic> productInfo,
  }) async {
    try {
      final result = await SupabaseService.client.from('messages').insert({
        'chat_id': chatId,
        'sender_id': senderId,
        'sender_role': senderRole,
        'content': jsonEncode(productInfo),
        'type': 'product_card',
      }).select('id, created_at').maybeSingle();

      if (result != null) {
        final msg = Message(
          id: result['id'] as String,
          chatId: chatId,
          senderId: senderId,
          senderRole: senderRole,
          content: jsonEncode(productInfo),
          type: 'product_card',
          createdAt: DateTime.parse(result['created_at'] as String),
        );
        final updated = List<Message>.from(state.messages)..add(msg);
        emit(state.copyWith(messages: updated));
      }
    } catch (e) {
      print('[ChatCubit] sendProductCard error: $e');
    }
  }

  /// Vendor sends a delivery fee request (negotiate or split) into the chat.
  Future<void> sendDeliveryFeeRequest({
    required String chatId,
    required String senderId,
    required String type, // 'negotiate' | 'split'
    required double buyerFee,
    required double vendorFee,
    String? recipientId,
  }) async {
    final messageType = type == 'split' ? 'delivery_split_request' : 'delivery_fee_request';
    final content = type == 'split'
        ? 'Delivery fee request: ₦${buyerFee.toStringAsFixed(0)} (you) + ₦${vendorFee.toStringAsFixed(0)} (vendor covers)'
        : 'Delivery fee request: ₦${buyerFee.toStringAsFixed(0)}';
    try {
      final result = await SupabaseService.client.from('messages').insert({
        'chat_id': chatId,
        'sender_id': senderId,
        'sender_role': 'vendor',
        'content': content,
        'type': messageType,
        'delivery_fee_amount': buyerFee + vendorFee,
        'buyer_fee_amount': buyerFee,
        'vendor_contribution': vendorFee,
        'delivery_fee_status': 'pending',
      }).select('id, created_at').maybeSingle();

      if (result == null) return;

      final msg = Message(
        id: result['id'] as String,
        chatId: chatId,
        senderId: senderId,
        senderRole: 'vendor',
        content: content,
        type: messageType,
        createdAt: DateTime.parse(result['created_at'] as String),
        deliveryFeeAmount: buyerFee + vendorFee,
        buyerFeeAmount: buyerFee,
        vendorContribution: vendorFee,
        deliveryFeeStatus: 'pending',
      );
      final updated = List<Message>.from(state.messages)..add(msg);
      emit(state.copyWith(messages: updated));

      if (recipientId != null) {
        await NotificationService.showChatNotification(title: 'Vendor', body: content);
        PushService.sendPush(
          userId: recipientId,
          title: 'Delivery Fee Request',
          body: content,
          data: {'type': 'chat', 'chatId': chatId},
        );
        await NotificationCubit.create(
          userId: recipientId,
          title: 'Delivery Fee Request',
          body: content,
          type: 'chat',
          referenceId: chatId,
        );
      }
    } catch (e) {
      print('[ChatCubit] sendDeliveryFeeRequest error: $e');
    }
  }

  /// Buyer accepts a pending delivery fee/split request — supersedes any
  /// previously accepted request, updates the order (if one exists yet),
  /// and posts a confirmation. Pre-purchase chats (no real order row yet)
  /// pass [updateOrder] = false; checkout reads the accepted message
  /// directly instead of relying on the orders table in that case.
  Future<bool> acceptDeliveryFee({
    required Message message,
    required String orderId,
    required double orderTotal,
    required String currentUserId,
    bool updateOrder = true,
  }) async {
    try {
      await SupabaseService.client
          .from('messages')
          .update({'delivery_fee_status': 'superseded'})
          .eq('chat_id', message.chatId)
          .eq('delivery_fee_status', 'accepted');

      await SupabaseService.client
          .from('messages')
          .update({'delivery_fee_status': 'accepted'})
          .eq('id', message.id);

      final buyerFee = message.buyerFeeAmount ?? 0;
      final vendorContribution = message.vendorContribution ?? 0;
      if (updateOrder) {
        await SupabaseService.client.from('orders').update({
          'delivery_fee': buyerFee,
          'vendor_delivery_contribution': vendorContribution,
          'total_with_delivery': orderTotal + buyerFee,
        }).eq('id', orderId);
      }

      final updatedMessages = state.messages.map((m) {
        if (m.id == message.id) {
          return Message(
            id: m.id,
            chatId: m.chatId,
            senderId: m.senderId,
            senderRole: m.senderRole,
            content: m.content,
            type: m.type,
            replyToId: m.replyToId,
            replyToContent: m.replyToContent,
            replyToSender: m.replyToSender,
            readAt: m.readAt,
            createdAt: m.createdAt,
            deliveryFeeAmount: m.deliveryFeeAmount,
            vendorContribution: m.vendorContribution,
            buyerFeeAmount: m.buyerFeeAmount,
            deliveryFeeStatus: 'accepted',
          );
        }
        return m;
      }).toList();
      emit(state.copyWith(messages: updatedMessages));

      final confirmContent = '✅ Delivery fee agreed: You pay ₦${buyerFee.toStringAsFixed(0)}. Held securely in escrow.';
      final confirmResult = await SupabaseService.client.from('messages').insert({
        'chat_id': message.chatId,
        'sender_id': currentUserId,
        'sender_role': 'buyer',
        'content': confirmContent,
        'type': 'text',
      }).select('id, created_at').maybeSingle();

      if (confirmResult != null) {
        final confirmMsg = Message(
          id: confirmResult['id'] as String,
          chatId: message.chatId,
          senderId: currentUserId,
          senderRole: 'buyer',
          content: confirmContent,
          type: 'text',
          createdAt: DateTime.parse(confirmResult['created_at'] as String),
        );
        final withConfirm = List<Message>.from(state.messages)..add(confirmMsg);
        emit(state.copyWith(messages: withConfirm));
      }
      return true;
    } catch (e) {
      print('[ChatCubit] acceptDeliveryFee error: $e');
      return false;
    }
  }

  Future<void> declineDeliveryFee({
    required Message message,
    required String currentUserId,
  }) async {
    try {
      await SupabaseService.client
          .from('messages')
          .update({'delivery_fee_status': 'declined'})
          .eq('id', message.id);

      final updatedMessages = state.messages.map((m) {
        if (m.id == message.id) {
          return Message(
            id: m.id,
            chatId: m.chatId,
            senderId: m.senderId,
            senderRole: m.senderRole,
            content: m.content,
            type: m.type,
            replyToId: m.replyToId,
            replyToContent: m.replyToContent,
            replyToSender: m.replyToSender,
            readAt: m.readAt,
            createdAt: m.createdAt,
            deliveryFeeAmount: m.deliveryFeeAmount,
            vendorContribution: m.vendorContribution,
            buyerFeeAmount: m.buyerFeeAmount,
            deliveryFeeStatus: 'declined',
          );
        }
        return m;
      }).toList();
      emit(state.copyWith(messages: updatedMessages));

      const declineContent = '❌ Delivery fee declined. Vendor can send a new offer.';
      final result = await SupabaseService.client.from('messages').insert({
        'chat_id': message.chatId,
        'sender_id': currentUserId,
        'sender_role': 'buyer',
        'content': declineContent,
        'type': 'text',
      }).select('id, created_at').maybeSingle();

      if (result != null) {
        final declineMsg = Message(
          id: result['id'] as String,
          chatId: message.chatId,
          senderId: currentUserId,
          senderRole: 'buyer',
          content: declineContent,
          type: 'text',
          createdAt: DateTime.parse(result['created_at'] as String),
        );
        final withDecline = List<Message>.from(state.messages)..add(declineMsg);
        emit(state.copyWith(messages: withDecline));
      }
    } catch (e) {
      print('[ChatCubit] declineDeliveryFee error: $e');
    }
  }

  // ── Phase 4: markChatRead only when needed + RPC ──

  Future<void> markChatRead(String chatId, String userId) async {
    try {
      // Check if there are actually unread messages before firing update
      final currentUnread = state.unreadCounts[chatId] ?? 0;
      if (currentUnread == 0) return;

      // Try RPC first (bypasses per-row RLS), fallback to direct update
      try {
        await SupabaseService.client.rpc('mark_chat_read', params: {
          'p_chat_id': chatId,
          'p_user_id': userId,
        });
      } catch (_) {
        // Fallback if RPC not deployed yet
        await SupabaseService.client
            .from('messages')
            .update({'read_at': DateTime.now().toIso8601String()})
            .eq('chat_id', chatId)
            .neq('sender_id', userId)
            .isFilter('read_at', null);
      }

      // Clear local unread count
      final updatedCounts = Map<String, int>.from(state.unreadCounts);
      updatedCounts.remove(chatId);
      emit(state.copyWith(unreadCounts: updatedCounts));
    } catch (e) {
      print('[ChatCubit] markChatRead error: $e');
    }
  }

  // ── Phase 5: Realtime with reconnect + read_at updates ──

  void _subscribeToMessages(String chatId) {
    _messagesChannel?.unsubscribe();
    _reconnectTimer?.cancel();

    _messagesChannel = SupabaseService.client
        .channel('messages:$chatId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'chat_id',
            value: chatId,
          ),
          callback: (payload) {
            final newMsg = Message.fromJson(payload.newRecord);
            // Avoid duplicates (optimistic send may have already added it)
            if (state.messages.any((m) => m.id == newMsg.id)) return;
            final updated = List<Message>.from(state.messages)..add(newMsg);
            emit(state.copyWith(messages: updated));
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'chat_id',
            value: chatId,
          ),
          callback: (payload) {
            // Phase 5: Handle read_at + delivery_fee_status updates live
            final updatedRecord = payload.newRecord;
            final msgId = updatedRecord['id'] as String;
            if (state.messages.any((m) => m.id == msgId)) {
              final refreshed = Message.fromJson(updatedRecord);
              final updated = state.messages.map((m) => m.id == msgId ? refreshed : m).toList();
              emit(state.copyWith(messages: updated));
            }
          },
        )
        .subscribe((status, [error]) {
      if (status == RealtimeSubscribeStatus.channelError || error != null) {
        print('[ChatCubit] Realtime error ($status), reconnecting in 3s...');
        _scheduleReconnect(chatId);
      }
    });

    // Phase 5: Heartbeat to detect dead connections
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_messagesChannel == null) {
        _scheduleReconnect(chatId);
      }
    });
  }

  void _scheduleReconnect(String chatId) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      print('[ChatCubit] Reconnecting to messages:$chatId');
      _subscribeToMessages(chatId);
    });
  }

  void disposeRealtime() {
    _messagesChannel?.unsubscribe();
    _messagesChannel = null;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
  }

  @override
  Future<void> close() {
    disposeRealtime();
    return super.close();
  }
}

class ChatState {
  final List<Chat> chats;
  final String? currentChatId;
  final List<Message> messages;
  final Map<String, int> unreadCounts;
  final Map<String, Message> lastMessages;
  final bool hasMoreMessages;

  ChatState({
    this.chats = const [],
    this.currentChatId,
    this.messages = const [],
    this.unreadCounts = const {},
    this.lastMessages = const {},
    this.hasMoreMessages = true,
  });

  ChatState copyWith({
    List<Chat>? chats,
    String? currentChatId,
    List<Message>? messages,
    Map<String, int>? unreadCounts,
    Map<String, Message>? lastMessages,
    bool? hasMoreMessages,
  }) {
    return ChatState(
      chats: chats ?? this.chats,
      currentChatId: currentChatId ?? this.currentChatId,
      messages: messages ?? this.messages,
      unreadCounts: unreadCounts ?? this.unreadCounts,
      lastMessages: lastMessages ?? this.lastMessages,
      hasMoreMessages: hasMoreMessages ?? this.hasMoreMessages,
    );
  }
}
