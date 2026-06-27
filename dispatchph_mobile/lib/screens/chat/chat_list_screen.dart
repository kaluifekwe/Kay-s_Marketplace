import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/cache_service.dart';
import '../../widgets/online_indicator.dart';
import 'chat_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  Map<String, String> _userNames = {};
  Map<String, bool> _onlineStatus = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadChats());
  }

  Future<void> _loadChats() async {
    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString('auth_role') ?? 'buyer';
    final userId = prefs.getString('auth_user_id') ?? '';
    if (userId.isEmpty || !mounted) return;
    if (role == 'vendor') {
      await context.read<ChatCubit>().loadChatsForVendor(userId);
    } else {
      await context.read<ChatCubit>().loadChatsForBuyer(userId);
    }
    await _loadNames();
  }

  Future<void> _loadNames() async {
    final chats = context.read<ChatCubit>().state.chats;
    final names = <String, String>{};
    final online = <String, bool>{};

    final buyerIds = <String>{};
    final vendorIds = <String>{};
    for (final chat in chats) {
      buyerIds.add(chat.buyerId);
      vendorIds.add(chat.vendorId);
    }

    // Phase 4: Check cache first, only fetch misses
    final uncachedBuyers = <String>{};
    for (final id in buyerIds) {
      final cached = CacheService.get<String>('userName_$id');
      if (cached != null) {
        names[id] = cached;
      } else {
        uncachedBuyers.add(id);
      }
    }

    final uncachedVendors = <String>{};
    for (final id in vendorIds) {
      final cached = CacheService.get<String>('userName_$id');
      if (cached != null) {
        names[id] = cached;
      } else {
        uncachedVendors.add(id);
      }
    }

    if (uncachedBuyers.isNotEmpty) {
      final buyerData = await SupabaseService.client
          .from('users')
          .select('id, name, last_active')
          .inFilter('id', uncachedBuyers.toList());
      for (final b in (buyerData as List)) {
        final user = AppUser.fromJson(b);
        names[b['id']] = user.name;
        online[b['id']] = AuthService.isOnline(user);
        CacheService.set('userName_${b['id']}', user.name, ttl: const Duration(minutes: 10));
        CacheService.set('online_${b['id']}', AuthService.isOnline(user), ttl: const Duration(seconds: 30));
      }
    }

    if (uncachedVendors.isNotEmpty) {
      final storeData = await SupabaseService.client
          .from('stores')
          .select('id, name, vendor_id')
          .inFilter('vendor_id', uncachedVendors.toList());
      for (final s in (storeData as List)) {
        final name = s['name'] as String? ?? 'Vendor';
        names[s['vendor_id']] = name;
        CacheService.set('userName_${s['vendor_id']}', name, ttl: const Duration(minutes: 10));
      }

      final vendorData = await SupabaseService.client
          .from('users')
          .select('id, last_active')
          .inFilter('id', uncachedVendors.toList());
      for (final v in (vendorData as List)) {
        final isOnline = AuthService.isOnline(AppUser.fromJson(v));
        online[v['id']] = isOnline;
        CacheService.set('online_${v['id']}', isOnline, ttl: const Duration(seconds: 30));
      }
    }

    if (mounted) setState(() { _userNames = names; _onlineStatus = online; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chats')),
      body: BlocBuilder<ChatCubit, ChatState>(
        builder: (context, state) {
          if (state.chats.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 64, color: AppColors.mediumGray),
                  const SizedBox(height: 16),
                  const Text('No conversations yet', style: TextStyle(color: AppColors.mediumGray)),
                  const SizedBox(height: 8),
                  const Text(
                    'Messages will appear when you contact a vendor or receive an order',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.mediumGray, fontSize: 12),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _loadChats,
            child: ListView.separated(
              itemCount: state.chats.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                indent: 72,
                color: Colors.grey.withAlpha(40),
              ),
              itemBuilder: (_, i) {
                final chat = state.chats[i];
                final unread = state.unreadCounts[chat.id] ?? 0;
                final lastMsg = state.lastMessages[chat.id];
                final otherName = _userNames[chat.vendorId] ?? 'Vendor';
                final lastMsgText = lastMsg != null
                    ? (lastMsg.type == 'text' ? lastMsg.content : '📎 ${lastMsg.type}')
                    : 'No messages yet';
                final lastMsgTime = lastMsg != null ? _formatTime(lastMsg.createdAt) : '';
                final isUnread = unread > 0;

                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: AppColors.primaryGreen.withAlpha(30),
                        child: Text(
                          otherName.isNotEmpty ? otherName[0].toUpperCase() : 'V',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryGreen,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: OnlineIndicator(isOnline: _onlineStatus[chat.vendorId] ?? false),
                      ),
                      if (isUnread)
                        Positioned(
                          right: -2,
                          top: -2,
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '$unread',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  ),
                  title: Text(
                    otherName,
                    style: TextStyle(
                      fontWeight: isUnread ? FontWeight.bold : FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  subtitle: Text(
                    lastMsgText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isUnread ? AppColors.charcoal : AppColors.mediumGray,
                      fontWeight: isUnread ? FontWeight.w500 : FontWeight.normal,
                      fontSize: 13,
                    ),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        lastMsgTime,
                        style: TextStyle(
                          color: isUnread ? AppColors.primaryGreen : AppColors.mediumGray,
                          fontSize: 12,
                          fontWeight: isUnread ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatScreen(
                          orderId: chat.orderId,
                          buyerId: chat.buyerId,
                          vendorId: chat.vendorId,
                          vendorName: _userNames[chat.vendorId] ?? 'Vendor',
                          buyerName: _userNames[chat.buyerId] ?? 'Buyer',
                        ),
                      ),
                    );
                    _loadChats();
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.day == now.day && dt.month == now.month && dt.year == now.year) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    final diff = now.difference(dt);
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return DateFormat('EEE').format(dt);
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
