import 'dart:convert';

class AppUser {
  final String id;
  final String email;
  final String name;
  final String role;
  final String? phone;
  final String? nin;
  final String? storeId;
  final String? address;
  final String? uniqueId;
  final DateTime createdAt;
  final DateTime? lastActive;

  AppUser({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    this.phone,
    this.nin,
    this.storeId,
    this.address,
    this.uniqueId,
    required this.createdAt,
    this.lastActive,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        email: (json['email'] as String?) ?? '',
        name: (json['name'] as String?) ?? 'User',
        role: (json['role'] as String?) ?? 'buyer',
        phone: json['phone'] as String?,
        nin: json['nin'] as String?,
        storeId: json['store_id'] as String?,
        address: json['address'] as String?,
        uniqueId: json['unique_id'] as String?,
        createdAt: json['created_at'] != null
            ? DateTime.parse(json['created_at'] as String)
            : DateTime.now(),
        lastActive: json['last_active'] != null
            ? DateTime.parse(json['last_active'] as String)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'name': name,
        'role': role,
        'phone': phone,
        'nin': nin,
        'store_id': storeId,
        'address': address,
        'unique_id': uniqueId,
        'created_at': createdAt.toIso8601String(),
        'last_active': lastActive?.toIso8601String(),
      };
}

class Store {
  final String id;
  final String vendorId;
  final String name;
  final String? description;
  final String? logoPath;
  final String? address;
  final String? phone;
  final DateTime createdAt;
  final String? whatsappNumber;
  final bool showPhoneToBuyers;
  final String? storeBannerUrl;
  final String? responseTime;
  final bool isVerified;
  final String? handle;

  Store({
    required this.id,
    required this.vendorId,
    required this.name,
    this.description,
    this.logoPath,
    this.address,
    this.phone,
    required this.createdAt,
    this.whatsappNumber,
    this.showPhoneToBuyers = true,
    this.storeBannerUrl,
    this.responseTime,
    this.isVerified = false,
    this.handle,
  });

  factory Store.fromJson(Map<String, dynamic> json) => Store(
        id: json['id'] as String,
        vendorId: json['vendor_id'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        logoPath: json['logo_path'] as String?,
        address: json['address'] as String?,
        phone: json['phone'] as String?,
        createdAt: json['created_at'] != null ? DateTime.parse(json['created_at'] as String) : DateTime.now(),
        whatsappNumber: json['whatsapp_number'] as String?,
        showPhoneToBuyers: json['show_phone_to_buyers'] as bool? ?? true,
        storeBannerUrl: json['store_banner_url'] as String?,
        responseTime: json['response_time'] as String?,
        isVerified: json['is_verified'] as bool? ?? false,
        handle: json['handle'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'vendor_id': vendorId,
        'name': name,
        'description': description,
        'logo_path': logoPath,
        'address': address,
        'phone': phone,
        'created_at': createdAt.toIso8601String(),
        'whatsapp_number': whatsappNumber,
        'show_phone_to_buyers': showPhoneToBuyers,
        'store_banner_url': storeBannerUrl,
        'response_time': responseTime,
        'is_verified': isVerified,
      };
}

class Product {
  final String id;
  final String storeId;
  final String name;
  final String? description;
  final double price;
  final String images; // JSON string
  final String? category;
  final int stock;
  final DateTime createdAt;
  final String? vendorState;
  final String deliveryType;

  Product({
    required this.id,
    required this.storeId,
    required this.name,
    this.description,
    required this.price,
    required this.images,
    this.category,
    required this.stock,
    required this.createdAt,
    this.vendorState,
    this.deliveryType = 'courier',
  });

  List<String> get imageList {
    try {
      if (images.isEmpty || images == '[]') return [];
      final decoded = jsonDecode(images);
      if (decoded is List) return decoded.cast<String>();
      return [];
    } catch (_) {
      return [];
    }
  }

  factory Product.fromJson(Map<String, dynamic> json) => Product(
        id: json['id'] as String,
        storeId: json['store_id'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        price: (json['price'] as num).toDouble(),
        images: json['images'] as String? ?? '[]',
        category: json['category'] as String?,
        stock: json['stock'] as int? ?? 0,
        createdAt: DateTime.parse(json['created_at'] as String),
        vendorState: json['vendor_state'] as String?,
        deliveryType: json['delivery_type'] as String? ?? 'courier',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'store_id': storeId,
        'name': name,
        'description': description,
        'price': price,
        'images': images,
        'category': category,
        'stock': stock,
        'created_at': createdAt.toIso8601String(),
        'delivery_type': deliveryType,
      };
}

class ProductVariant {
  final String? id;
  final String productId;
  final String label;
  final double price;
  final int stock;
  final String? imageUrl;
  final int sortOrder;

  ProductVariant({
    this.id,
    required this.productId,
    required this.label,
    required this.price,
    required this.stock,
    this.imageUrl,
    this.sortOrder = 0,
  });

  factory ProductVariant.fromJson(Map<String, dynamic> json) => ProductVariant(
        id: json['id'] as String?,
        productId: json['product_id'] as String,
        label: json['label'] as String,
        price: (json['price'] as num).toDouble(),
        stock: json['stock'] as int? ?? 0,
        imageUrl: json['image_url'] as String?,
        sortOrder: json['sort_order'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'product_id': productId,
        'label': label,
        'price': price,
        'stock': stock,
        'image_url': imageUrl,
        'sort_order': sortOrder,
      };
}

class CartItem {
  final String id;
  final String buyerId;
  final String productId;
  final int quantity;
  final DateTime addedAt;
  final String? variantLabel;
  final double? variantPrice;

  CartItem({
    required this.id,
    required this.buyerId,
    required this.productId,
    required this.quantity,
    required this.addedAt,
    this.variantLabel,
    this.variantPrice,
  });

  factory CartItem.fromJson(Map<String, dynamic> json) => CartItem(
        id: json['id'] as String,
        buyerId: json['buyer_id'] as String,
        productId: json['product_id'] as String,
        quantity: json['quantity'] as int? ?? 1,
        addedAt: DateTime.parse(json['added_at'] as String),
        variantLabel: json['variant_label'] as String?,
        variantPrice: json['variant_price'] != null ? (json['variant_price'] as num).toDouble() : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'buyer_id': buyerId,
        'product_id': productId,
        'quantity': quantity,
        'added_at': addedAt.toIso8601String(),
        'variant_label': variantLabel,
        'variant_price': variantPrice,
      };

  double get unitPrice => variantPrice ?? 0;
}

class Order {
  final String id;
  final String buyerId;
  final String vendorId;
  final String storeId;
  final String items; // JSON string
  final double total;
  final String status;
  final String? paymentReference;
  final String? shippingMethod;
  final String? trackingRef;
  final String? riderName;
  final String? riderPhone;
  final String? deliveryMethod;
  final String? shippingProofUrl;
  final String? deliveryPhotoUrl;
  final bool paymentReleased;
  final DateTime? paidAt;
  final DateTime? shippedAt;
  final DateTime? deliveredAt;
  final DateTime? confirmedAt;
  final DateTime? autoReleaseAt;
  final DateTime? shippingPhotoAt;
  final DateTime? refundedAt;
  final DateTime createdAt;
  final String? deliveryType;
  final double deliveryFee;
  final double vendorDeliveryContribution;
  final double? totalWithDelivery;
  final bool hasShipbubbleDelivery;
  final String? deliveryId;
  final DateTime? pickupDeadline;

  Order({
    required this.id,
    required this.buyerId,
    required this.vendorId,
    required this.storeId,
    required this.items,
    required this.total,
    required this.status,
    this.paymentReference,
    this.shippingMethod,
    this.trackingRef,
    this.riderName,
    this.riderPhone,
    this.deliveryMethod,
    this.shippingProofUrl,
    this.deliveryPhotoUrl,
    this.paymentReleased = false,
    this.paidAt,
    this.shippedAt,
    this.deliveredAt,
    this.confirmedAt,
    this.autoReleaseAt,
    this.shippingPhotoAt,
    this.refundedAt,
    required this.createdAt,
    this.deliveryType,
    this.deliveryFee = 0,
    this.vendorDeliveryContribution = 0,
    this.totalWithDelivery,
    this.hasShipbubbleDelivery = false,
    this.deliveryId,
    this.pickupDeadline,
  });

  factory Order.fromJson(Map<String, dynamic> json) => Order(
        id: json['id'] as String,
        buyerId: json['buyer_id'] as String,
        vendorId: json['vendor_id'] as String,
        storeId: json['store_id'] as String,
        items: json['items'] as String? ?? '[]',
        total: (json['total'] as num).toDouble(),
        status: json['status'] as String? ?? 'paid',
        paymentReference: json['payment_reference'] as String?,
        shippingMethod: json['shipping_method'] as String?,
        trackingRef: json['tracking_ref'] as String?,
        riderName: json['rider_name'] as String?,
        riderPhone: json['rider_phone'] as String?,
        deliveryMethod: json['delivery_method'] as String?,
        shippingProofUrl: json['shipping_proof_url'] as String?,
        deliveryPhotoUrl: json['delivery_photo_url'] as String?,
        paymentReleased: json['payment_released'] as bool? ?? false,
        paidAt: json['paid_at'] != null ? DateTime.parse(json['paid_at'] as String) : null,
        shippedAt: json['shipped_at'] != null ? DateTime.parse(json['shipped_at'] as String) : null,
        deliveredAt: json['delivered_at'] != null ? DateTime.parse(json['delivered_at'] as String) : null,
        confirmedAt: json['confirmed_at'] != null ? DateTime.parse(json['confirmed_at'] as String) : null,
        autoReleaseAt: json['auto_release_at'] != null ? DateTime.parse(json['auto_release_at'] as String) : null,
        shippingPhotoAt: json['shipping_photo_at'] != null ? DateTime.parse(json['shipping_photo_at'] as String) : null,
        refundedAt: json['refunded_at'] != null ? DateTime.parse(json['refunded_at'] as String) : null,
        createdAt: DateTime.parse(json['created_at'] as String),
        deliveryType: json['delivery_type'] as String?,
        deliveryFee: json['delivery_fee'] != null ? (json['delivery_fee'] as num).toDouble() : 0,
        vendorDeliveryContribution: json['vendor_delivery_contribution'] != null
            ? (json['vendor_delivery_contribution'] as num).toDouble()
            : 0,
        totalWithDelivery: json['total_with_delivery'] != null ? (json['total_with_delivery'] as num).toDouble() : null,
        hasShipbubbleDelivery: json['has_shipbubble_delivery'] as bool? ?? false,
        deliveryId: json['delivery_id'] as String?,
        pickupDeadline: json['pickup_deadline'] != null ? DateTime.tryParse(json['pickup_deadline'] as String) : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'buyer_id': buyerId,
        'vendor_id': vendorId,
        'store_id': storeId,
        'items': items,
        'total': total,
        'status': status,
        'shipping_method': shippingMethod,
        'tracking_ref': trackingRef,
        'rider_name': riderName,
        'rider_phone': riderPhone,
        'delivery_method': deliveryMethod,
        'shipping_proof_url': shippingProofUrl,
        'delivery_photo_url': deliveryPhotoUrl,
        'payment_released': paymentReleased,
        'paid_at': paidAt?.toIso8601String(),
        'shipped_at': shippedAt?.toIso8601String(),
        'delivered_at': deliveredAt?.toIso8601String(),
        'confirmed_at': confirmedAt?.toIso8601String(),
        'auto_release_at': autoReleaseAt?.toIso8601String(),
        'shipping_photo_at': shippingPhotoAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'delivery_type': deliveryType,
        'delivery_fee': deliveryFee,
        'vendor_delivery_contribution': vendorDeliveryContribution,
        'total_with_delivery': totalWithDelivery,
      };
}

class Chat {
  final String id;
  final String orderId;
  final String buyerId;
  final String vendorId;
  final DateTime createdAt;

  Chat({
    required this.id,
    required this.orderId,
    required this.buyerId,
    required this.vendorId,
    required this.createdAt,
  });

  factory Chat.fromJson(Map<String, dynamic> json) => Chat(
        id: json['id'] as String,
        orderId: json['order_id'] as String,
        buyerId: json['buyer_id'] as String,
        vendorId: json['vendor_id'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'order_id': orderId,
        'buyer_id': buyerId,
        'vendor_id': vendorId,
        'created_at': createdAt.toIso8601String(),
      };
}

class Message {
  final String id;
  final String chatId;
  final String senderId;
  final String senderRole;
  final String content;
  final String type;
  final String? replyToId;
  final String? replyToContent;
  final String? replyToSender;
  final DateTime? readAt;
  final DateTime createdAt;
  final double? deliveryFeeAmount;
  final double? vendorContribution;
  final double? buyerFeeAmount;
  final String? deliveryFeeStatus;

  Message({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.senderRole,
    required this.content,
    required this.type,
    this.replyToId,
    this.replyToContent,
    this.replyToSender,
    this.readAt,
    required this.createdAt,
    this.deliveryFeeAmount,
    this.vendorContribution,
    this.buyerFeeAmount,
    this.deliveryFeeStatus,
  });

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        chatId: json['chat_id'] as String,
        senderId: json['sender_id'] as String,
        senderRole: json['sender_role'] as String,
        content: json['content'] as String,
        type: json['type'] as String? ?? 'text',
        replyToId: json['reply_to_id'] as String?,
        replyToContent: json['reply_to_content'] as String?,
        replyToSender: json['reply_to_sender'] as String?,
        readAt: json['read_at'] != null ? DateTime.parse(json['read_at'] as String) : null,
        createdAt: DateTime.parse(json['created_at'] as String),
        deliveryFeeAmount: json['delivery_fee_amount'] != null ? (json['delivery_fee_amount'] as num).toDouble() : null,
        vendorContribution: json['vendor_contribution'] != null ? (json['vendor_contribution'] as num).toDouble() : null,
        buyerFeeAmount: json['buyer_fee_amount'] != null ? (json['buyer_fee_amount'] as num).toDouble() : null,
        deliveryFeeStatus: json['delivery_fee_status'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'chat_id': chatId,
        'sender_id': senderId,
        'sender_role': senderRole,
        'content': content,
        'type': type,
        'reply_to_id': replyToId,
        'reply_to_content': replyToContent,
        'reply_to_sender': replyToSender,
        'read_at': readAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'delivery_fee_amount': deliveryFeeAmount,
        'vendor_contribution': vendorContribution,
        'buyer_fee_amount': buyerFeeAmount,
        'delivery_fee_status': deliveryFeeStatus,
      };

  Message copyWith({String? id, DateTime? createdAt, DateTime? readAt}) => Message(
        id: id ?? this.id,
        chatId: chatId,
        senderId: senderId,
        senderRole: senderRole,
        content: content,
        type: type,
        replyToId: replyToId,
        replyToContent: replyToContent,
        replyToSender: replyToSender,
        readAt: readAt ?? this.readAt,
        createdAt: createdAt ?? this.createdAt,
        deliveryFeeAmount: deliveryFeeAmount,
        vendorContribution: vendorContribution,
        buyerFeeAmount: buyerFeeAmount,
        deliveryFeeStatus: deliveryFeeStatus,
      );
}

class Dispute {
  final String id;
  final String orderId;
  final String raisedBy;
  final String buyerId;
  final String vendorId;
  final String reason;
  final String? buyerExplanation;
  final String? buyerPhone;
  final String? deliveryAddress;
  final String? issueType;
  final String evidenceUrls; // JSON array
  final String vendorEvidenceUrls; // JSON array
  final String status;
  final String? vendorResponse;
  final String? resolutionType;
  final String? replacementProductId;
  final bool escalatedToAdmin;
  final DateTime? resolutionDeadline;
  final DateTime? buyerSubmittedAt;
  final DateTime? vendorRespondedAt;
  final DateTime? resolvedAt;
  final DateTime createdAt;
  final DateTime? vendorResponseDeadline;
  final String? adminDecision;
  final String? adminNotes;
  final bool returnRequired;
  final DateTime? returnDeadline;
  final String returnReceiptPhotos; // JSON array: [packageUrl, handoverUrl]
  final bool returnVerified;
  final String? refundMethod;
  final String? videoUrl;
  final DateTime? vendorConfirmDeadline;
  final DateTime? vendorReturnConfirmedAt;
  final String? vendorReturnReceivedPhoto;
  final bool isPostPayment;
  final double vendorOwesRefund;

  Dispute({
    required this.id,
    required this.orderId,
    required this.raisedBy,
    required this.buyerId,
    required this.vendorId,
    required this.reason,
    this.buyerExplanation,
    this.buyerPhone,
    this.deliveryAddress,
    this.issueType,
    this.evidenceUrls = '[]',
    this.vendorEvidenceUrls = '[]',
    required this.status,
    this.vendorResponse,
    this.resolutionType,
    this.replacementProductId,
    this.escalatedToAdmin = false,
    this.resolutionDeadline,
    this.buyerSubmittedAt,
    this.vendorRespondedAt,
    this.resolvedAt,
    required this.createdAt,
    this.vendorResponseDeadline,
    this.adminDecision,
    this.adminNotes,
    this.returnRequired = false,
    this.returnDeadline,
    this.returnReceiptPhotos = '[]',
    this.returnVerified = false,
    this.refundMethod,
    this.videoUrl,
    this.vendorConfirmDeadline,
    this.vendorReturnConfirmedAt,
    this.vendorReturnReceivedPhoto,
    this.isPostPayment = false,
    this.vendorOwesRefund = 0,
  });

  List<String> get evidenceList {
    try {
      if (evidenceUrls.isEmpty || evidenceUrls == '[]') return [];
      final decoded = jsonDecode(evidenceUrls);
      if (decoded is List) return decoded.cast<String>();
      return [];
    } catch (_) {
      return [];
    }
  }

  List<String> get vendorEvidenceList {
    try {
      if (vendorEvidenceUrls.isEmpty || vendorEvidenceUrls == '[]') return [];
      final decoded = jsonDecode(vendorEvidenceUrls);
      if (decoded is List) return decoded.cast<String>();
      return [];
    } catch (_) {
      return [];
    }
  }

  List<String> get returnReceiptPhotosList {
    try {
      if (returnReceiptPhotos.isEmpty || returnReceiptPhotos == '[]') return [];
      final decoded = jsonDecode(returnReceiptPhotos);
      if (decoded is List) return decoded.cast<String>();
      return [];
    } catch (_) {
      return [];
    }
  }

  String? get vendorConfirmTimeRemaining {
    if (vendorConfirmDeadline == null) return null;
    final diff = vendorConfirmDeadline!.difference(DateTime.now());
    if (diff.isNegative) return 'Expired';
    if (diff.inHours > 0) return '${diff.inHours}h ${diff.inMinutes % 60}m';
    return '${diff.inMinutes}m';
  }

  bool get isEscalated => escalatedToAdmin ||
      (resolutionDeadline != null && resolutionDeadline!.isBefore(DateTime.now()));

  String? get timeRemaining {
    if (resolutionDeadline == null) return null;
    final diff = resolutionDeadline!.difference(DateTime.now());
    if (diff.isNegative) return 'Escalated';
    if (diff.inHours > 24) return '${diff.inHours ~/ 24}d ${diff.inHours % 24}h';
    if (diff.inHours > 0) return '${diff.inHours}h ${diff.inMinutes % 60}m';
    return '${diff.inMinutes}m';
  }

  factory Dispute.fromJson(Map<String, dynamic> json) => Dispute(
        id: json['id'] as String,
        orderId: json['order_id'] as String,
        raisedBy: json['raised_by'] as String,
        buyerId: json['buyer_id'] as String? ?? json['raised_by'] as String? ?? '',
        vendorId: json['vendor_id'] as String? ?? '',
        reason: json['reason'] as String,
        buyerExplanation: json['buyer_explanation'] as String?,
        buyerPhone: json['buyer_phone'] as String?,
        deliveryAddress: json['delivery_address'] as String?,
        issueType: json['issue_type'] as String?,
        evidenceUrls: json['evidence_urls'] as String? ?? '[]',
        vendorEvidenceUrls: json['vendor_evidence_urls'] as String? ?? '[]',
        status: json['status'] as String? ?? 'open',
        vendorResponse: json['vendor_response'] as String?,
        resolutionType: json['resolution_type'] as String?,
        replacementProductId: json['replacement_product_id'] as String?,
        escalatedToAdmin: json['escalated_to_admin'] as bool? ?? false,
        resolutionDeadline: json['resolution_deadline'] != null 
            ? DateTime.parse(json['resolution_deadline'] as String) : null,
        buyerSubmittedAt: json['buyer_submitted_at'] != null 
            ? DateTime.parse(json['buyer_submitted_at'] as String) : null,
        vendorRespondedAt: json['vendor_responded_at'] != null 
            ? DateTime.parse(json['vendor_responded_at'] as String) : null,
        resolvedAt: json['resolved_at'] != null
            ? DateTime.parse(json['resolved_at'] as String) : null,
        createdAt: DateTime.parse(json['created_at'] as String),
        vendorResponseDeadline: json['vendor_response_deadline'] != null
            ? DateTime.parse(json['vendor_response_deadline'] as String) : null,
        adminDecision: json['admin_decision'] as String?,
        adminNotes: json['admin_notes'] as String?,
        returnRequired: json['return_required'] as bool? ?? false,
        returnDeadline: json['return_deadline'] != null
            ? DateTime.parse(json['return_deadline'] as String) : null,
        returnReceiptPhotos: json['return_receipt_photos'] as String? ?? '[]',
        returnVerified: json['return_verified'] as bool? ?? false,
        refundMethod: json['refund_method'] as String?,
        videoUrl: json['video_url'] as String?,
        vendorConfirmDeadline: json['vendor_confirm_deadline'] != null
            ? DateTime.parse(json['vendor_confirm_deadline'] as String) : null,
        vendorReturnConfirmedAt: json['vendor_return_confirmed_at'] != null
            ? DateTime.parse(json['vendor_return_confirmed_at'] as String) : null,
        vendorReturnReceivedPhoto: json['vendor_return_received_photo'] as String?,
        isPostPayment: json['is_post_payment'] as bool? ?? false,
        vendorOwesRefund: (json['vendor_owes_refund'] as num?)?.toDouble() ?? 0,
      );

  String? get vendorTimeRemaining {
    if (vendorResponseDeadline == null) return null;
    final diff = vendorResponseDeadline!.difference(DateTime.now());
    if (diff.isNegative) return 'Expired';
    if (diff.inHours > 0) return '${diff.inHours}h ${diff.inMinutes % 60}m';
    return '${diff.inMinutes}m';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'order_id': orderId,
        'raised_by': raisedBy,
        'buyer_id': buyerId,
        'vendor_id': vendorId,
        'reason': reason,
        'buyer_explanation': buyerExplanation,
        'buyer_phone': buyerPhone,
        'delivery_address': deliveryAddress,
        'issue_type': issueType,
        'evidence_urls': evidenceUrls,
        'vendor_evidence_urls': vendorEvidenceUrls,
        'status': status,
        'vendor_response': vendorResponse,
        'resolution_type': resolutionType,
        'replacement_product_id': replacementProductId,
        'escalated_to_admin': escalatedToAdmin,
        'resolution_deadline': resolutionDeadline?.toIso8601String(),
        'buyer_submitted_at': buyerSubmittedAt?.toIso8601String(),
        'vendor_responded_at': vendorRespondedAt?.toIso8601String(),
        'resolved_at': resolvedAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
      };
}

class Review {
  final String id;
  final String storeId;
  final String userId;
  final String? orderId;
  final int rating;
  final String? comment;
  final DateTime createdAt;
  final String? buyerName;

  Review({
    required this.id,
    required this.storeId,
    required this.userId,
    this.orderId,
    required this.rating,
    this.comment,
    required this.createdAt,
    this.buyerName,
  });

  factory Review.fromJson(Map<String, dynamic> json) => Review(
        id: json['id'] as String,
        storeId: json['store_id'] as String,
        userId: json['user_id'] as String,
        orderId: json['order_id'] as String?,
        rating: json['rating'] as int,
        comment: json['comment'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        buyerName: json['users'] is Map ? (json['users']['name'] as String?) : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'store_id': storeId,
        'user_id': userId,
        'order_id': orderId,
        'rating': rating,
        'comment': comment,
        'created_at': createdAt.toIso8601String(),
      };
}

class AppNotification {
  final String id;
  final String userId;
  final String title;
  final String body;
  final String type;
  final String? referenceId;
  final bool isRead;
  final DateTime createdAt;

  AppNotification({
    required this.id,
    required this.userId,
    required this.title,
    required this.body,
    required this.type,
    this.referenceId,
    required this.isRead,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        title: json['title'] as String,
        body: json['body'] as String,
        type: (json['type'] as String?) ?? 'general',
        referenceId: json['reference_id'] as String?,
        isRead: (json['is_read'] as bool?) ?? false,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class CreditTransaction {
  final String id;
  final String buyerId;
  final double amount;
  final String type;
  final String? orderId;
  final String? description;
  final DateTime? expiresAt;
  final DateTime createdAt;

  CreditTransaction({
    required this.id,
    required this.buyerId,
    required this.amount,
    required this.type,
    this.orderId,
    this.description,
    this.expiresAt,
    required this.createdAt,
  });

  factory CreditTransaction.fromJson(Map<String, dynamic> json) => CreditTransaction(
        id: json['id'] as String,
        buyerId: json['buyer_id'] as String,
        amount: (json['amount'] as num).toDouble(),
        type: json['type'] as String,
        orderId: json['order_id'] as String?,
        description: json['description'] as String?,
        expiresAt: json['expires_at'] != null ? DateTime.parse(json['expires_at'] as String) : null,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}
