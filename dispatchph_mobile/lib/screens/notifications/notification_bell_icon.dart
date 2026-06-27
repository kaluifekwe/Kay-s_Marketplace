import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../bloc_exports.dart';

class NotificationBellIcon extends StatelessWidget {
  final VoidCallback onPressed;
  const NotificationBellIcon({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(38),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.notifications_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          BlocBuilder<NotificationCubit, NotificationState>(
            builder: (context, state) {
              if (state.unreadCount <= 0) return const SizedBox.shrink();
              return Positioned(
                right: 2,
                top: 2,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    state.unreadCount > 99 ? '99+' : '${state.unreadCount}',
                    style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
