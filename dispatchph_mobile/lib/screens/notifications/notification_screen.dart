import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../orders/order_detail_screen.dart';
import '../chat/chat_list_screen.dart';
import '../disputes/vendor_disputes_screen.dart';
import '../orders/buyer_dispute_screen.dart';

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  String _userId = '';
  String _userRole = 'buyer';

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  Future<void> _loadNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString('auth_user_id') ?? '';
    _userRole = prefs.getString('auth_role') ?? 'buyer';
    if (_userId.isNotEmpty && mounted) {
      context.read<NotificationCubit>().loadNotifications(_userId);
    }
  }

  void _onTapNotification(AppNotification n) {
    context.read<NotificationCubit>().markAsRead(n.id);

    final ref = n.referenceId;
    switch (n.type) {
      case 'order':
      case 'vendor_order':
        if (ref != null) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: ref)));
          return;
        }
        break;
      case 'chat':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatListScreen()));
        return;
      case 'dispute':
        if (_userRole == 'vendor') {
          Navigator.push(context, MaterialPageRoute(builder: (_) => const VendorDisputesScreen()));
          return;
        } else if (ref != null) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => BuyerDisputeScreen(disputeId: ref)));
          return;
        }
        break;
    }
    // No screen to open (or no reference) — show the notification's own content
    // so tapping always does something readable instead of nothing.
    _showNotificationContent(n);
  }

  void _showNotificationContent(AppNotification n) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(n.title),
        content: Text(n.body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'order':
        return Icons.receipt_long;
      case 'vendor_order':
        return Icons.inventory_2;
      case 'chat':
        return Icons.chat_bubble;
      case 'dispute':
        return Icons.gavel;
      default:
        return Icons.notifications;
    }
  }

  Color _colorForType(String type) {
    switch (type) {
      case 'order':
        return AppColors.primaryGreen;
      case 'vendor_order':
        return AppColors.escrowBlue;
      case 'chat':
        return AppColors.primaryBlue;
      case 'dispute':
        return AppColors.errorRed;
      default:
        return AppColors.mediumGray;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          BlocBuilder<NotificationCubit, NotificationState>(
            builder: (context, state) {
              if (state.notifications.isEmpty) return const SizedBox();
              return PopupMenuButton<String>(
                onSelected: (value) async {
                  if (value == 'read_all') {
                    context.read<NotificationCubit>().markAllAsRead(_userId);
                  } else if (value == 'delete_all') {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Clear all notifications?'),
                        content: const Text('This cannot be undone.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Delete All', style: TextStyle(color: AppColors.errorRed)),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      context.read<NotificationCubit>().deleteAllNotifications(_userId);
                    }
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'read_all', child: Text('Mark all as read')),
                  const PopupMenuItem(value: 'delete_all', child: Text('Delete all')),
                ],
              );
            },
          ),
        ],
      ),
      body: BlocBuilder<NotificationCubit, NotificationState>(
        builder: (context, state) {
          if (state.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.notifications.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_none, size: 64, color: AppColors.mediumGray),
                  const SizedBox(height: 16),
                  const Text('No notifications yet', style: TextStyle(color: AppColors.mediumGray)),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => context.read<NotificationCubit>().loadNotifications(_userId),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: state.notifications.length,
              itemBuilder: (_, i) {
                final n = state.notifications[i];
                final timeAgo = _formatTimeAgo(n.createdAt);
                return Dismissible(
                  key: Key(n.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    color: AppColors.errorRed,
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (_) {
                    context.read<NotificationCubit>().deleteNotification(n.id);
                  },
                  child: ListTile(
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _colorForType(n.type).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(_iconForType(n.type), color: _colorForType(n.type), size: 20),
                    ),
                    title: Text(
                      n.title,
                      style: TextStyle(
                        fontWeight: n.isRead ? FontWeight.normal : FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      n.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: n.isRead ? AppColors.mediumGray : AppColors.charcoal,
                      ),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(timeAgo, style: const TextStyle(fontSize: 11, color: AppColors.mediumGray)),
                        if (!n.isRead)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(top: 4),
                            decoration: const BoxDecoration(
                              color: AppColors.primaryGreen,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    onTap: () => _onTapNotification(n),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    final dateStr = DateFormat('MMM d, h:mm a').format(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago • $dateStr';
    if (diff.inHours < 24) return '${diff.inHours}h ago • $dateStr';
    if (diff.inDays < 7) return '${diff.inDays}d ago • $dateStr';
    return dateStr;
  }
}
