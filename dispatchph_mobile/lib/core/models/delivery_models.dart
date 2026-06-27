// Models for the Shipbubble courier delivery integration.
//
// Architectural note: courier booking is automatic. The buyer picks a courier
// at checkout (CourierOption from a DeliveryQuote); the selection is threaded
// through create-payment and the order's courier is booked server-side by
// paystack-webhook -> book-delivery after payment. The vendor never books a
// courier from the app. See shipbubble_delivery.sql for the schema.

/// A vendor's saved pickup location (sender address for Shipbubble).
class VendorLocation {
  final String id;
  final String vendorId;
  final String label; // "Main Shop", "Warehouse", "Home", "Other"
  final String address;
  final String landmark; // required for NG addresses
  final String city; // Lagos | Abuja | Port Harcourt
  final String state;
  final double? latitude;
  final double? longitude;
  final bool isDefault;
  final bool isVerified;
  final DateTime? createdAt;

  VendorLocation({
    required this.id,
    required this.vendorId,
    required this.label,
    required this.address,
    required this.landmark,
    required this.city,
    required this.state,
    this.latitude,
    this.longitude,
    this.isDefault = false,
    this.isVerified = false,
    this.createdAt,
  });

  factory VendorLocation.fromJson(Map<String, dynamic> json) => VendorLocation(
        id: json['id'] as String,
        vendorId: json['vendor_id'] as String,
        label: json['label'] as String? ?? 'Other',
        address: json['address'] as String? ?? '',
        landmark: json['landmark'] as String? ?? '',
        city: json['city'] as String? ?? '',
        state: json['state'] as String? ?? '',
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        isDefault: json['is_default'] as bool? ?? false,
        isVerified: json['is_verified'] as bool? ?? false,
        createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at'] as String) : null,
      );
}

/// A buyer's saved delivery address (receiver address for Shipbubble).
class BuyerAddress {
  final String id;
  final String buyerId;
  final String label; // "Home", "Office", "Mum's Place", "Other"
  final String address;
  final String landmark; // required for NG addresses
  final String city;
  final String state;
  final double? latitude;
  final double? longitude;
  final bool isDefault;
  final bool isVerified;
  final DateTime? createdAt;

  BuyerAddress({
    required this.id,
    required this.buyerId,
    required this.label,
    required this.address,
    required this.landmark,
    required this.city,
    required this.state,
    this.latitude,
    this.longitude,
    this.isDefault = false,
    this.isVerified = false,
    this.createdAt,
  });

  factory BuyerAddress.fromJson(Map<String, dynamic> json) => BuyerAddress(
        id: json['id'] as String,
        buyerId: json['buyer_id'] as String,
        label: json['label'] as String? ?? 'Other',
        address: json['address'] as String? ?? '',
        landmark: json['landmark'] as String? ?? '',
        city: json['city'] as String? ?? '',
        state: json['state'] as String? ?? '',
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        isDefault: json['is_default'] as bool? ?? false,
        isVerified: json['is_verified'] as bool? ?? false,
        createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at'] as String) : null,
      );
}

/// One courier option inside a delivery quote, as returned (already mapped and
/// sorted cheapest-first) by the get-delivery-quotes Edge Function.
class CourierOption {
  final String name;
  final String? logo;
  final double fee;
  final String currency;
  final String? eta;
  final String? serviceCode;
  final String? courierId;

  CourierOption({
    required this.name,
    this.logo,
    required this.fee,
    this.currency = 'NGN',
    this.eta,
    this.serviceCode,
    this.courierId,
  });

  factory CourierOption.fromJson(Map<String, dynamic> json) => CourierOption(
        name: json['name'] as String? ?? 'Courier',
        logo: json['logo'] as String?,
        fee: (json['fee'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'NGN',
        eta: json['eta']?.toString(),
        serviceCode: json['service_code']?.toString(),
        courierId: json['courier_id']?.toString(),
      );
}

/// Result of get-delivery-quotes. An empty [couriers] list (with a [reason]) is
/// the signal to fall back to the in-chat delivery-fee negotiation flow.
class DeliveryQuote {
  final String? quoteId;
  final List<CourierOption> couriers;
  final String? reason; // e.g. vendor_no_pickup_location, no_rates, address_validation_failed

  DeliveryQuote({this.quoteId, this.couriers = const [], this.reason});

  bool get hasCouriers => quoteId != null && couriers.isNotEmpty;

  factory DeliveryQuote.fromJson(Map<String, dynamic> json) => DeliveryQuote(
        quoteId: json['quote_id'] as String?,
        couriers: (json['couriers'] as List?)
                ?.map((c) => CourierOption.fromJson(Map<String, dynamic>.from(c as Map)))
                .toList() ??
            const [],
        reason: json['reason'] as String?,
      );
}

/// A booked courier delivery (deliveries table).
class Delivery {
  final String id;
  final String orderId;
  final String vendorId;
  final String buyerId;
  final String? shipbubbleOrderId;
  final String? courierName;
  final String? courierPhone;
  final String? trackingUrl;
  final String pickupAddress;
  final String? pickupLandmark;
  final String pickupCity;
  final double? pickupLatitude;
  final double? pickupLongitude;
  final String deliveryAddress;
  final String? deliveryLandmark;
  final String deliveryCity;
  final double? deliveryLatitude;
  final double? deliveryLongitude;
  final String? itemName;
  final double shipbubbleFee;
  final double buyerCharged;
  final String status; // pending|confirmed|picked_up|in_transit|delivered|failed|cancelled
  final DateTime? bookedAt;
  final DateTime? pickedUpAt;
  final DateTime? deliveredAt;
  final String? estimatedDelivery;

  Delivery({
    required this.id,
    required this.orderId,
    required this.vendorId,
    required this.buyerId,
    this.shipbubbleOrderId,
    this.courierName,
    this.courierPhone,
    this.trackingUrl,
    required this.pickupAddress,
    this.pickupLandmark,
    required this.pickupCity,
    this.pickupLatitude,
    this.pickupLongitude,
    required this.deliveryAddress,
    this.deliveryLandmark,
    required this.deliveryCity,
    this.deliveryLatitude,
    this.deliveryLongitude,
    this.itemName,
    this.shipbubbleFee = 0,
    this.buyerCharged = 0,
    this.status = 'pending',
    this.bookedAt,
    this.pickedUpAt,
    this.deliveredAt,
    this.estimatedDelivery,
  });

  factory Delivery.fromJson(Map<String, dynamic> json) => Delivery(
        id: json['id'] as String,
        orderId: json['order_id'] as String,
        vendorId: json['vendor_id'] as String,
        buyerId: json['buyer_id'] as String,
        shipbubbleOrderId: json['shipbubble_order_id'] as String?,
        courierName: json['courier_name'] as String?,
        courierPhone: json['courier_phone'] as String?,
        trackingUrl: json['tracking_url'] as String?,
        pickupAddress: json['pickup_address'] as String? ?? '',
        pickupLandmark: json['pickup_landmark'] as String?,
        pickupCity: json['pickup_city'] as String? ?? '',
        pickupLatitude: (json['pickup_latitude'] as num?)?.toDouble(),
        pickupLongitude: (json['pickup_longitude'] as num?)?.toDouble(),
        deliveryAddress: json['delivery_address'] as String? ?? '',
        deliveryLandmark: json['delivery_landmark'] as String?,
        deliveryCity: json['delivery_city'] as String? ?? '',
        deliveryLatitude: (json['delivery_latitude'] as num?)?.toDouble(),
        deliveryLongitude: (json['delivery_longitude'] as num?)?.toDouble(),
        itemName: json['item_name'] as String?,
        shipbubbleFee: (json['shipbubble_fee'] as num?)?.toDouble() ?? 0,
        buyerCharged: (json['buyer_charged'] as num?)?.toDouble() ?? 0,
        status: json['status'] as String? ?? 'pending',
        bookedAt: json['booked_at'] != null ? DateTime.tryParse(json['booked_at'] as String) : null,
        pickedUpAt: json['picked_up_at'] != null ? DateTime.tryParse(json['picked_up_at'] as String) : null,
        deliveredAt: json['delivered_at'] != null ? DateTime.tryParse(json['delivered_at'] as String) : null,
        estimatedDelivery: json['estimated_delivery'] as String?,
      );

  bool get hasPickupCoords => pickupLatitude != null && pickupLongitude != null;
  bool get hasDeliveryCoords => deliveryLatitude != null && deliveryLongitude != null;
}

/// A single tracking event (delivery_tracking table).
class DeliveryTrackingEvent {
  final String id;
  final String deliveryId;
  final String status;
  final String? description;
  final String? location;
  final DateTime timestamp;

  DeliveryTrackingEvent({
    required this.id,
    required this.deliveryId,
    required this.status,
    this.description,
    this.location,
    required this.timestamp,
  });

  factory DeliveryTrackingEvent.fromJson(Map<String, dynamic> json) => DeliveryTrackingEvent(
        id: json['id'] as String,
        deliveryId: json['delivery_id'] as String,
        status: json['status'] as String? ?? '',
        description: json['description'] as String?,
        location: json['location'] as String?,
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}
