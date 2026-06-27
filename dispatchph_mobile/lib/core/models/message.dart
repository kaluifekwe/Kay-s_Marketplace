class Message {
  final String id;
  final String chatId;
  final String senderId;
  final String senderRole; // buyer, vendor
  final String content;
  final String type; // text, image
  final DateTime? readAt;
  final DateTime createdAt;

  Message({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.senderRole,
    required this.content,
    this.type = 'text',
    this.readAt,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isMine => senderRole == 'buyer';
}
