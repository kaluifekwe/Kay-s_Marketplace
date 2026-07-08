import 'package:flutter/material.dart';

Widget deliveryBadge(String? deliveryType) {
  switch (deliveryType) {
    case 'free':
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_shipping, size: 12, color: Color(0xFF1A8A2E)),
          const SizedBox(width: 3),
          Text(
            'Free Delivery',
            style: TextStyle(fontSize: 11, color: const Color(0xFF1A8A2E), fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );
    case 'split':
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.handshake, size: 12, color: Colors.blue[700]),
          const SizedBox(width: 3),
          Text(
            'Split delivery fee',
            style: TextStyle(fontSize: 11, color: Colors.blue[700]),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );
    case 'negotiate':
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline, size: 12, color: Colors.orange[700]),
          const SizedBox(width: 3),
          Text(
            'Chat for delivery fee',
            style: TextStyle(fontSize: 11, color: Colors.orange[700]),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );
    case 'courier':
    default:
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_shipping, size: 12, color: Color(0xFF1A8A2E)),
          const SizedBox(width: 3),
          Text(
            'Courier delivery',
            style: TextStyle(fontSize: 11, color: const Color(0xFF1A8A2E), fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );
  }
}
