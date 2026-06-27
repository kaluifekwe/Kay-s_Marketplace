import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../bloc_exports.dart';

class ChatBadgeIcon extends StatelessWidget {
  final VoidCallback onPressed;
  const ChatBadgeIcon({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ChatCubit, ChatState>(
      builder: (context, state) {
        final totalUnread = state.unreadCounts.values.fold<int>(0, (sum, c) => sum + c);
        return IconButton(
          onPressed: onPressed,
          icon: Badge(
            isLabelVisible: totalUnread > 0,
            label: Text(
              totalUnread > 99 ? '99+' : '$totalUnread',
              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
            ),
            backgroundColor: Colors.red,
            alignment: AlignmentDirectional.topEnd,
            offset: const Offset(-2, 2),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.chat_bubble_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        );
      },
    );
  }
}
