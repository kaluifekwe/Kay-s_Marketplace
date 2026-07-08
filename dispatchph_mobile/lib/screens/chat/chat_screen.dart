import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:gal/gal.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/cache_service.dart';
import '../../core/services/storage_service.dart';
import '../../widgets/online_indicator.dart';
import '../../widgets/app_image.dart';

class ChatScreen extends StatefulWidget {
  final String orderId;
  final String buyerId;
  final String vendorId;
  final String vendorName;
  final String buyerName;
  final Map<String, dynamic>? productInfo;

  const ChatScreen({
    super.key,
    required this.orderId,
    required this.buyerId,
    required this.vendorId,
    required this.vendorName,
    this.buyerName = 'Buyer',
    this.productInfo,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  String? _currentUserId;
  String? _currentRole;
  Message? _replyToMessage;
  bool _otherUserOnline = false;
  bool _chatLoading = true;
  bool _uploading = false;
  bool _autoScroll = true;
  int _prevMessageCount = 0;
  bool _downloading = false;
  String? _orderDeliveryType;
  double _orderTotal = 0;
  bool _isRealOrder = false;

  /// Delivery type for this chat: prefers the real order's type (set once
  /// payment has happened), but falls back to the product's delivery_type
  /// passed in via productInfo for pre-purchase chats — so the vendor can
  /// negotiate the fee before checkout, not just after.
  String? get _chatDeliveryType => _orderDeliveryType ?? widget.productInfo?['deliveryType'] as String?;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initChat();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final atBottom = _scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 60;
    if (_autoScroll != atBottom) {
      _autoScroll = atBottom;
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  Future<void> _initChat() async {
    final authUser = SupabaseService.auth.currentUser;
    if (authUser == null) return;
    _currentUserId = authUser.id;

    final prefs = await SharedPreferences.getInstance();
    _currentRole = prefs.getString('auth_role') ?? 'buyer';
    print('[ChatScreen] _initChat role=$_currentRole userId=$_currentUserId');
    if (!mounted) return;

    final buyerId = _currentRole == 'buyer' ? _currentUserId! : widget.buyerId;
    final vendorId = _currentRole == 'vendor' ? _currentUserId! : widget.vendorId;

    // Phase 4: Parallelize openChat + user profile fetch
    final otherId = _currentRole == 'buyer' ? widget.vendorId : widget.buyerId;
    await Future.wait([
      context.read<ChatCubit>().openChat(widget.orderId, buyerId, vendorId, currentUserId: _currentUserId),
      _fetchOtherUserOnline(otherId),
      _fetchOrderDeliveryInfo(),
    ]);

    if (!mounted) return;
    setState(() => _chatLoading = false);
    _scrollToBottom();

    final chatId = context.read<ChatCubit>().state.currentChatId;
    print('[ChatScreen] After openChat: chatId=$chatId');

    if (widget.productInfo != null && _currentUserId != null && chatId != null) {
      final existing = context.read<ChatCubit>().state.messages;
      final hasProductCard = existing.any((m) => m.type == 'product_card');
      if (!hasProductCard) {
        await context.read<ChatCubit>().sendProductCard(
          chatId: chatId,
          senderId: _currentUserId!,
          senderRole: _currentRole ?? 'buyer',
          productInfo: widget.productInfo!,
        );
        _scrollToBottom();
      }
    }
  }

  Future<void> _fetchOrderDeliveryInfo() async {
    // Pre-purchase chats use a placeholder orderId of 'product_<id>'. Look
    // the delivery type up directly from the product instead of relying on
    // productInfo being passed in — productInfo is only set the first time
    // the buyer opens the chat from the product page; reopening the same
    // chat later (e.g. the vendor opening it from their Messages list)
    // never passes it, which previously made the delivery-fee button
    // silently disappear for the vendor.
    if (widget.orderId.startsWith('product_')) {
      final productId = widget.orderId.substring('product_'.length);
      try {
        final data = await SupabaseService.client
            .from('products')
            .select('delivery_type')
            .eq('id', productId)
            .maybeSingle();
        if (data != null && mounted) {
          setState(() => _orderDeliveryType = data['delivery_type'] as String?);
        }
      } catch (e) {
        print('[ChatScreen] _fetchOrderDeliveryInfo (product) error: $e');
      }
      return;
    }
    try {
      final data = await SupabaseService.client
          .from('orders')
          .select('delivery_type, total, delivery_fee, vendor_delivery_contribution, total_with_delivery')
          .eq('id', widget.orderId)
          .maybeSingle();
      if (data != null && mounted) {
        setState(() {
          _isRealOrder = true;
          _orderDeliveryType = data['delivery_type'] as String?;
          _orderTotal = (data['total'] as num?)?.toDouble() ?? 0;
        });
      }
    } catch (e) {
      print('[ChatScreen] _fetchOrderDeliveryInfo error: $e');
    }
  }

  Future<void> _fetchOtherUserOnline(String otherId) async {
    // Phase 4: Cache user online status with 30s TTL
    final cached = CacheService.get<bool>('online_$otherId');
    if (cached != null) {
      if (mounted) setState(() => _otherUserOnline = cached);
      return;
    }
    try {
      final userData = await SupabaseService.client
          .from('public_profiles')
          .select('id, last_active')
          .eq('id', otherId)
          .maybeSingle();
      if (userData != null) {
        final user = AppUser.fromJson(userData);
        final isOnline = AuthService.isOnline(user);
        CacheService.set('online_$otherId', isOnline, ttl: const Duration(seconds: 30));
        if (mounted) setState(() => _otherUserOnline = isOnline);
      }
    } catch (e) {
      print('[ChatScreen] _fetchOtherUserOnline error: $e');
    }
  }

  @override
  void dispose() {
    // Tear down this chat's realtime channels + typing timers on exit. The
    // ChatCubit is app-scoped, so reopening a chat re-subscribes cleanly.
    context.read<ChatCubit>().disposeRealtime();
    _msgController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;
    final authUser = SupabaseService.auth.currentUser;
    if (authUser == null) {
      _showError('Not logged in. Please log in again.');
      return;
    }
    _currentUserId = authUser.id;
    final chatId = context.read<ChatCubit>().state.currentChatId;
    if (chatId == null) {
      _showError('Chat not loaded. Please go back and reopen.');
      return;
    }

    String? replyToId;
    String? replyToContent;
    String? replyToSender;
    if (_replyToMessage != null) {
      replyToId = _replyToMessage!.id;
      replyToContent = _replyToMessage!.type == 'text' ? _replyToMessage!.content : '📎 ${_replyToMessage!.type}';
      replyToSender = _replyToMessage!.senderRole == 'buyer' ? widget.buyerName : widget.vendorName;
    }

    final recipientId = _currentRole == 'buyer' ? widget.vendorId : widget.buyerId;

    await context.read<ChatCubit>().sendMessage(
      chatId: chatId,
      senderId: _currentUserId!,
      senderRole: _currentRole ?? 'buyer',
      content: text,
      replyToId: replyToId,
      replyToContent: replyToContent,
      replyToSender: replyToSender,
      recipientId: recipientId,
    );
    _msgController.clear();
    setState(() => _replyToMessage = null);
    _scrollToBottom();
  }

  void _cancelReply() {
    setState(() => _replyToMessage = null);
  }

  /// Tick state for one of MY messages: sending → sent → delivered → read
  /// (or failed). Delivered/read are derived from the other participant's
  /// per-conversation markers, so there are no per-message status writes.
  String _tickFor(dynamic msg, ChatState state) {
    final ls = state.localStatus[msg.id];
    if (ls == 'sending') return 'sending';
    if (ls == 'failed') return 'failed';
    final created = msg.createdAt as DateTime;
    if (state.otherLastRead != null && !state.otherLastRead!.isBefore(created)) return 'read';
    if (state.otherLastDelivered != null && !state.otherLastDelivered!.isBefore(created)) {
      return 'delivered';
    }
    return 'sent';
  }

  Future<void> _sendImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (picked == null) return;
    final authUser = SupabaseService.auth.currentUser;
    if (authUser == null) return;
    _currentUserId = authUser.id;
    final chatId = context.read<ChatCubit>().state.currentChatId;
    if (chatId == null) return;
    final recipientId = _currentRole == 'buyer' ? widget.vendorId : widget.buyerId;

    setState(() => _uploading = true);
    final url = await StorageService.uploadChatMedia(
      chatId: chatId,
      filePath: picked.path,
      type: 'image',
    );
    setState(() => _uploading = false);

    if (url == null) {
      _showError('Failed to upload image. Please try again.');
      return;
    }

    await context.read<ChatCubit>().sendMessage(
      chatId: chatId,
      senderId: _currentUserId!,
      senderRole: _currentRole ?? 'buyer',
      content: url,
      type: 'image',
      recipientId: recipientId,
    );
    _scrollToBottom();
  }

  Future<void> _sendVideo() async {
    final picked = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 60));
    if (picked == null) return;
    final authUser = SupabaseService.auth.currentUser;
    if (authUser == null) return;
    _currentUserId = authUser.id;
    final chatId = context.read<ChatCubit>().state.currentChatId;
    if (chatId == null) return;
    final recipientId = _currentRole == 'buyer' ? widget.vendorId : widget.buyerId;

    setState(() => _uploading = true);
    final url = await StorageService.uploadChatMedia(
      chatId: chatId,
      filePath: picked.path,
      type: 'video',
    );
    setState(() => _uploading = false);

    if (url == null) {
      _showError('Failed to upload video. Please try again.');
      return;
    }

    await context.read<ChatCubit>().sendMessage(
      chatId: chatId,
      senderId: _currentUserId!,
      senderRole: _currentRole ?? 'buyer',
      content: url,
      type: 'video',
      recipientId: recipientId,
    );
    _scrollToBottom();
  }

  void _scrollToBottom() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Save a chat image/video into the device's photo gallery (a "Kay's
  /// Marketplace" album). Reuses the cached file (images are already cached, so
  /// no re-download), copies it with a proper extension, then hands it to Gal,
  /// which handles Android MediaStore / iOS Photos + permissions.
  Future<void> _saveMediaToDevice(String url, {bool isVideo = false}) async {
    if (_downloading) return;
    setState(() => _downloading = true);
    final snack = ScaffoldMessenger.of(context);
    try {
      if (!await Gal.hasAccess()) {
        await Gal.requestAccess();
      }
      final cached = await DefaultCacheManager().getSingleFile(url);
      final ext = p.extension(Uri.parse(url).path).isNotEmpty
          ? p.extension(Uri.parse(url).path)
          : (isVideo ? '.mp4' : '.jpg');
      final tmpPath = '${Directory.systemTemp.path}/Kays_${DateTime.now().millisecondsSinceEpoch}$ext';
      final tmp = await cached.copy(tmpPath);

      if (isVideo) {
        await Gal.putVideo(tmp.path, album: "Kays Market");
      } else {
        await Gal.putImage(tmp.path, album: "Kays Market");
      }

      if (!mounted) return;
      snack.showSnackBar(const SnackBar(
        content: Text('Saved to your gallery'),
        backgroundColor: AppColors.primaryGreen,
      ));
    } on GalException {
      if (!mounted) return;
      snack.showSnackBar(SnackBar(
        content: const Text('Could not save to your gallery. Check the app\'s photo permission and try again.'),
        backgroundColor: Colors.red,
      ));
    } catch (e) {
      if (!mounted) return;
      snack.showSnackBar(const SnackBar(content: Text('Could not save media'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatTitle = _currentRole == 'vendor' ? widget.buyerName : widget.vendorName;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(chatTitle),
            const SizedBox(width: 8),
            OnlineIndicator(isOnline: _otherUserOnline, size: 10),
          ],
        ),
        actions: [
          // Always available to vendors — a chat isn't reliably tied to a
          // single product (e.g. a general "Chat in App" conversation), so
          // we can't always auto-detect free/negotiate/split. If it can't
          // be detected, _showDeliveryFeeSheet asks the vendor directly
          // rather than hiding the button.
          if ((_currentRole == 'vendor' || _currentUserId == widget.vendorId) && _chatDeliveryType != 'free')
            IconButton(
              icon: const Icon(Icons.local_shipping, color: Colors.white),
              tooltip: 'Send Delivery Fee Request',
              onPressed: _showDeliveryFeeSheet,
            ),
        ],
      ),
      body: _chatLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          Expanded(
            child: BlocBuilder<ChatCubit, ChatState>(
              builder: (context, state) {
                if (state.messages.isEmpty) {
                  _prevMessageCount = 0;
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline, size: 48, color: AppColors.mediumGray),
                        const SizedBox(height: 12),
                        const Text('No messages yet', style: TextStyle(color: AppColors.mediumGray)),
                        const Text('Send a message to start chatting',
                            style: TextStyle(color: AppColors.mediumGray, fontSize: 12)),
                      ],
                    ),
                  );
                }
                final msgCount = state.messages.length;
                if (_autoScroll && msgCount > _prevMessageCount && _prevMessageCount > 0) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
                }
                _prevMessageCount = msgCount;
                final chatId = state.currentChatId;
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: state.messages.length + (state.hasMoreMessages ? 1 : 0),
                  itemBuilder: (_, i) {
                    // Phase 3: Load more indicator at top
                    if (i == 0 && state.hasMoreMessages && chatId != null) {
                      return FutureBuilder(
                        future: Future(() async {
                          await context.read<ChatCubit>().loadMoreMessages(chatId);
                        }),
                        builder: (_, __) => const Padding(
                          padding: EdgeInsets.all(8),
                          child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                        ),
                      );
                    }
                    final msgIndex = state.hasMoreMessages ? i - 1 : i;
                    if (msgIndex < 0) return const SizedBox.shrink();
                    final msg = state.messages[msgIndex];
                    final isMine = msg.senderId == _currentUserId;
                    final senderName = msg.senderRole == 'buyer' ? widget.buyerName : widget.vendorName;
                    return _MessageBubble(
                      message: msg,
                      isMine: isMine,
                      senderName: senderName,
                      isVendor: _currentRole == 'vendor',
                      deliveryTick: isMine ? _tickFor(msg, state) : null,
                      onReply: () {
                        setState(() => _replyToMessage = msg);
                      },
                      onDownload: (msg.type == 'image' || msg.type == 'video')
                          ? () => _saveMediaToDevice(msg.content, isVideo: msg.type == 'video')
                          : null,
                      onAcceptDelivery: () => _acceptDeliveryFee(msg),
                      onDeclineDelivery: () => _declineDeliveryFee(msg),
                    );
                  },
                );
              },
            ),
          ),
          if (_replyToMessage != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primaryGreen.withAlpha(15),
                border: Border(
                  left: BorderSide(color: AppColors.primaryGreen, width: 3),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Replying to ${_replyToMessage!.senderRole == 'buyer' ? widget.buyerName : widget.vendorName}',
                          style: const TextStyle(
                            color: AppColors.primaryGreen,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _replyToMessage!.type == 'text' ? _replyToMessage!.content : '📎 ${_replyToMessage!.type}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.charcoal, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20, color: AppColors.mediumGray),
                    onPressed: _cancelReply,
                  ),
                ],
              ),
            ),
          if (_uploading)
            const LinearProgressIndicator(minHeight: 3),
          BlocBuilder<ChatCubit, ChatState>(
            buildWhen: (a, b) => a.otherTyping != b.otherTyping,
            builder: (context, state) {
              if (!state.otherTyping) return const SizedBox.shrink();
              final otherName = _currentRole == 'vendor' ? widget.buyerName : widget.vendorName;
              return Container(
                width: double.infinity,
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  '$otherName is typing…',
                  style: const TextStyle(
                    color: AppColors.primaryGreen,
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              );
            },
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file, color: AppColors.mediumGray),
                    onPressed: () => _showAttachMenu(),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _msgController,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        filled: true,
                        fillColor: AppColors.lightGray,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      onChanged: (_) {
                        final chatId = context.read<ChatCubit>().state.currentChatId;
                        if (chatId != null) context.read<ChatCubit>().sendTyping(chatId);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    backgroundColor: AppColors.primaryGreen,
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white, size: 20),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeliveryFeeSheet() {
    if (_chatDeliveryType == 'split') {
      _showSplitSheet();
      return;
    }
    if (_chatDeliveryType == 'negotiate') {
      _showNegotiateSheet();
      return;
    }
    // Type couldn't be auto-detected for this chat (e.g. a general inquiry
    // not tied to one product) — ask the vendor directly instead of
    // guessing or hiding the feature.
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('How should the delivery fee work?',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline, color: AppColors.primaryGreen),
              title: const Text('Buyer pays the full fee'),
              onTap: () {
                Navigator.pop(context);
                _showNegotiateSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.handshake, color: Colors.blue),
              title: const Text('Split the fee with buyer'),
              onTap: () {
                Navigator.pop(context);
                _showSplitSheet();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showNegotiateSheet() {
    final feeController = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('💬 Request Delivery Fee', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Buyer will pay the full delivery fee', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            const SizedBox(height: 16),
            TextFormField(
              controller: feeController,
              decoration: InputDecoration(
                labelText: 'Delivery fee amount',
                prefixText: '₦ ',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  final fee = double.tryParse(feeController.text.trim()) ?? 0;
                  if (fee <= 0) return;
                  Navigator.pop(context);
                  _sendDeliveryFeeRequest(type: 'negotiate', buyerFee: fee, vendorFee: 0);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryGreen,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Send Request', style: TextStyle(color: Colors.white, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSplitSheet() {
    final totalCostController = TextEditingController();
    final vendorShareController = TextEditingController();
    double vendorShare = 0;
    double buyerShare = 0;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('🤝 Request Split Delivery Fee', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                'Enter total delivery cost and how much each party pays',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: totalCostController,
                decoration: InputDecoration(
                  labelText: 'Total delivery cost',
                  prefixText: '₦ ',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                keyboardType: TextInputType.number,
                onChanged: (v) {
                  final total = double.tryParse(v) ?? 0;
                  vendorShareController.text = (total / 2).toStringAsFixed(0);
                  setSheetState(() {
                    vendorShare = total / 2;
                    buyerShare = total / 2;
                  });
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: vendorShareController,
                decoration: InputDecoration(
                  labelText: 'I will cover (₦)',
                  prefixText: '₦ ',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  helperText: 'Buyer pays the remainder',
                ),
                keyboardType: TextInputType.number,
                onChanged: (v) {
                  final total = double.tryParse(totalCostController.text) ?? 0;
                  final vShare = double.tryParse(v) ?? 0;
                  setSheetState(() {
                    vendorShare = vShare;
                    buyerShare = total - vShare;
                  });
                },
              ),
              const SizedBox(height: 12),
              if (buyerShare > 0)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5EB),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.primaryGreen),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Buyer pays', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          Text(
                            '₦${buyerShare.toStringAsFixed(0)}',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.primaryGreen),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text('You cover', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          Text(
                            '₦${vendorShare.toStringAsFixed(0)}',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue[700]),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: buyerShare <= 0
                      ? null
                      : () {
                          Navigator.pop(context);
                          _sendDeliveryFeeRequest(type: 'split', buyerFee: buyerShare, vendorFee: vendorShare);
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue[700],
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Send Split Request', style: TextStyle(color: Colors.white, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendDeliveryFeeRequest({
    required String type,
    required double buyerFee,
    required double vendorFee,
  }) async {
    final chatId = context.read<ChatCubit>().state.currentChatId;
    if (chatId == null || _currentUserId == null) return;
    await context.read<ChatCubit>().sendDeliveryFeeRequest(
      chatId: chatId,
      senderId: _currentUserId!,
      type: type,
      buyerFee: buyerFee,
      vendorFee: vendorFee,
      recipientId: widget.buyerId,
    );
    _scrollToBottom();
  }

  Future<void> _acceptDeliveryFee(Message message) async {
    if (_currentUserId == null) return;
    final ok = await context.read<ChatCubit>().acceptDeliveryFee(
      message: message,
      orderId: widget.orderId,
      orderTotal: _orderTotal,
      currentUserId: _currentUserId!,
      updateOrder: _isRealOrder,
    );
    if (!ok && mounted) {
      _showError('Could not accept delivery fee. Please try again.');
    }
    _scrollToBottom();
  }

  Future<void> _declineDeliveryFee(Message message) async {
    if (_currentUserId == null) return;
    await context.read<ChatCubit>().declineDeliveryFee(message: message, currentUserId: _currentUserId!);
    _scrollToBottom();
  }

  void _showAttachMenu() {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo, color: AppColors.primaryGreen),
              title: const Text('Send Image'),
              onTap: () {
                Navigator.pop(context);
                _sendImage();
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: AppColors.primaryGreen),
              title: const Text('Send Video'),
              onTap: () {
                Navigator.pop(context);
                _sendVideo();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final dynamic message;
  final bool isMine;
  final String senderName;
  final bool isVendor;
  final VoidCallback? onReply;
  final VoidCallback? onDownload;
  final VoidCallback? onAcceptDelivery;
  final VoidCallback? onDeclineDelivery;
  final String? deliveryTick;

  const _MessageBubble({
    required this.message,
    required this.isMine,
    required this.senderName,
    this.isVendor = false,
    this.onReply,
    this.onDownload,
    this.onAcceptDelivery,
    this.onDeclineDelivery,
    this.deliveryTick,
  });

  Widget? _buildTick() {
    if (!isMine || deliveryTick == null) return null;
    switch (deliveryTick) {
      case 'sending':
        return const Icon(Icons.access_time, size: 12, color: Colors.white70);
      case 'failed':
        return const Icon(Icons.error_outline, size: 13, color: Color(0xFFFFCDD2));
      case 'sent':
        return const Icon(Icons.done, size: 14, color: Colors.white70);
      case 'delivered':
        return const Icon(Icons.done_all, size: 14, color: Colors.white70);
      case 'read':
        return const Icon(Icons.done_all, size: 14, color: Color(0xFF7CC6FF));
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (message.type == 'product_card') {
      return _ProductCardBubble(message: message);
    }
    if (message.type == 'delivery_fee_request' || message.type == 'delivery_split_request') {
      final isSplit = message.type == 'delivery_split_request';
      final status = message.deliveryFeeStatus as String? ?? 'pending';
      final buyerPays = (message.buyerFeeAmount as double?) ?? 0;
      final vendorCovers = (message.vendorContribution as double?) ?? 0;
      return _DeliveryRequestBubble(
        icon: isSplit ? '🤝' : '💬',
        title: isSplit ? 'Split Delivery Fee Request' : 'Delivery Fee Request',
        description: isSplit
            ? 'Vendor proposes to share delivery cost'
            : 'Vendor requests ₦${buyerPays.toStringAsFixed(0)} for delivery',
        buyerPays: buyerPays,
        vendorCovers: vendorCovers,
        status: status,
        // Only the buyer (recipient, not the vendor who sent it) gets action buttons.
        showActions: !isVendor && status == 'pending',
        onAccept: onAcceptDelivery,
        onDecline: onDeclineDelivery,
      );
    }
    return GestureDetector(
      onLongPress: () => _showContextMenu(context),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: isMine ? AppColors.primaryGreen : Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: isMine ? const Radius.circular(16) : const Radius.circular(4),
              bottomRight: isMine ? const Radius.circular(4) : const Radius.circular(16),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(10),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isMine) ...[
                Text(
                  senderName,
                  style: const TextStyle(
                    color: AppColors.primaryGreen,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              if (message.replyToId != null && message.replyToContent != null) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: isMine ? Colors.white.withAlpha(20) : AppColors.lightGray,
                    borderRadius: BorderRadius.circular(8),
                    border: Border(
                      left: BorderSide(
                        color: isMine ? Colors.white54 : AppColors.primaryGreen,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.replyToSender ?? '',
                        style: TextStyle(
                          color: isMine ? Colors.white70 : AppColors.primaryGreen,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        message.replyToContent!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isMine ? Colors.white60 : AppColors.mediumGray,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (message.type == 'image') ...[
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: AppImage(
                        source: message.content,
                        width: 200,
                        height: 200,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: onDownload,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.download, color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else if (message.type == 'video') ...[
                Stack(
                  children: [
                    _VideoThumbnail(filePath: message.content),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: onDownload,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.download, color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                Text(
                  message.content,
                  style: TextStyle(
                    color: isMine ? Colors.white : AppColors.charcoal,
                    fontSize: 15,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(message.createdAt),
                    style: TextStyle(
                      color: isMine ? Colors.white70 : AppColors.mediumGray,
                      fontSize: 10,
                    ),
                  ),
                  if (_buildTick() != null) ...[
                    const SizedBox(width: 4),
                    _buildTick()!,
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            if (message.type == 'text')
              ListTile(
                leading: const Icon(Icons.copy, color: AppColors.mediumGray),
                title: const Text('Copy'),
                onTap: () {
                  Navigator.pop(context);
                },
              ),
            if (message.type == 'image' || message.type == 'video')
              ListTile(
                leading: const Icon(Icons.download, color: AppColors.primaryBlue),
                title: const Text('Save to device'),
                onTap: () {
                  Navigator.pop(context);
                  onDownload?.call();
                },
              ),
            ListTile(
              leading: const Icon(Icons.reply, color: AppColors.primaryGreen),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(context);
                onReply?.call();
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.day == now.day && dt.month == now.month && dt.year == now.year) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _VideoThumbnail extends StatefulWidget {
  final String filePath;
  const _VideoThumbnail({required this.filePath});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _isNetwork = false;

  @override
  void initState() {
    super.initState();
    _isNetwork = widget.filePath.startsWith('http://') || widget.filePath.startsWith('https://');
    _controller = _isNetwork
        ? VideoPlayerController.networkUrl(Uri.parse(widget.filePath))
        : VideoPlayerController.file(File(widget.filePath))
      ..initialize().then((_) {
        if (mounted) setState(() => _initialized = true);
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return Container(
        width: 200,
        height: 150,
        decoration: BoxDecoration(
          color: Colors.grey[300],
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return GestureDetector(
      onTap: () {
        _controller.value.isPlaying ? _controller.pause() : _controller.play();
        setState(() {});
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 200,
              height: 150,
              child: VideoPlayer(_controller),
            ),
          ),
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(50),
                  blurRadius: 8,
                ),
              ],
            ),
            child: Icon(
              _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeliveryRequestBubble extends StatelessWidget {
  final String icon;
  final String title;
  final String description;
  final double buyerPays;
  final double vendorCovers;
  final String status;
  final bool showActions;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;

  const _DeliveryRequestBubble({
    required this.icon,
    required this.title,
    required this.description,
    required this.buyerPays,
    required this.vendorCovers,
    required this.status,
    required this.showActions,
    this.onAccept,
    this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5EB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primaryGreen, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(icon, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.primaryGreen, fontSize: 14),
                ),
              ),
              if (status != 'pending')
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: status == 'accepted' ? AppColors.primaryGreen : Colors.grey[400],
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    status == 'accepted'
                        ? 'Accepted'
                        : status == 'declined'
                            ? 'Declined'
                            : 'Superseded',
                    style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(description, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('You pay:', style: TextStyle(fontSize: 13)),
                    Text(
                      '₦${buyerPays.toStringAsFixed(0)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.primaryGreen, fontSize: 15),
                    ),
                  ],
                ),
                if (vendorCovers > 0) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Vendor covers:', style: TextStyle(fontSize: 13)),
                      Text(
                        '₦${vendorCovers.toStringAsFixed(0)}',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue[700], fontSize: 15),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (showActions) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onDecline,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.red[300]!),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Decline', style: TextStyle(color: Colors.red)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: onAccept,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Accept ✅', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ProductCardBubble extends StatelessWidget {
  final dynamic message;
  const _ProductCardBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final product = jsonDecode(message.content) as Map<String, dynamic>;
    final format = NumberFormat('#,##0');
    final price = product['price'] is double ? product['price'] as double : 0.0;
    final imagePath = product['image'] as String?;

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        width: 260,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primaryGreen.withAlpha(80)),
          boxShadow: [
            BoxShadow(color: Colors.black.withAlpha(15), blurRadius: 8, offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              height: 120,
              decoration: BoxDecoration(
                color: AppColors.lightGray,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: imagePath != null && imagePath.isNotEmpty
                  ? ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                      child: AppImage(
                        source: imagePath,
                        fit: BoxFit.cover,
                      ),
                    )
                  : const Center(
                      child: Icon(Icons.inventory_2, size: 40, color: AppColors.mediumGray),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.primaryGreen.withAlpha(20),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'Product Inquiry',
                      style: TextStyle(
                        color: AppColors.primaryGreen,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    product['name'] ?? 'Product',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '\u20A6${format.format(price)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: AppColors.primaryGreen,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    product['storeName'] ?? '',
                    style: const TextStyle(color: AppColors.mediumGray, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
