import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/delivery_models.dart';
import 'supabase_service.dart';

/// Data + helper layer for the Shipbubble courier delivery integration.
///
/// Reads/writes vendor_locations, buyer_addresses, deliveries and
/// delivery_tracking directly (RLS-guarded), calls the get-delivery-quotes
/// Edge Function for live courier rates, and uses OSRM (OpenStreetMap routing,
/// no API key) to draw the route on the tracking map. Courier booking itself is
/// NOT done here — it happens server-side after payment (see book-delivery).
class DeliveryService {
  // Edge Functions identify the caller from this JWT, so attach it explicitly
  // (mirrors PaymentService). A stalled mobile connection must fail fast.
  static Map<String, String> get _authHeaders {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final session = SupabaseService.client.auth.currentSession;
    if (session != null && session.accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${session.accessToken}';
    }
    return headers;
  }

  // ---- Vendor pickup locations ----

  static Future<List<VendorLocation>> getVendorLocations(String vendorId) async {
    final rows = await SupabaseService.client
        .from('vendor_locations')
        .select()
        .eq('vendor_id', vendorId)
        .order('is_default', ascending: false)
        .order('created_at', ascending: true);
    return (rows as List).map((r) => VendorLocation.fromJson(Map<String, dynamic>.from(r as Map))).toList();
  }

  static Future<void> addVendorLocation({
    required String vendorId,
    required String label,
    required String address,
    required String landmark,
    required String city,
    required String state,
    double? latitude,
    double? longitude,
    required bool isDefault,
  }) async {
    // The first location a vendor adds is forced to default so the
    // get-delivery-quotes function always has a sender to resolve.
    final existing = await SupabaseService.client.from('vendor_locations').select('id').eq('vendor_id', vendorId);
    final makeDefault = isDefault || (existing as List).isEmpty;
    if (makeDefault) {
      await SupabaseService.client.from('vendor_locations').update({'is_default': false}).eq('vendor_id', vendorId);
    }
    await SupabaseService.client.from('vendor_locations').insert({
      'vendor_id': vendorId,
      'label': label,
      'address': address,
      'landmark': landmark,
      'city': city,
      'state': state,
      'latitude': latitude,
      'longitude': longitude,
      'is_default': makeDefault,
    });
  }

  static Future<void> setDefaultVendorLocation(String vendorId, String locationId) async {
    await SupabaseService.client.from('vendor_locations').update({'is_default': false}).eq('vendor_id', vendorId);
    await SupabaseService.client.from('vendor_locations').update({'is_default': true}).eq('id', locationId);
  }

  static Future<void> deleteVendorLocation(String locationId) async {
    await SupabaseService.client.from('vendor_locations').delete().eq('id', locationId);
  }

  // ---- Buyer delivery addresses ----

  static Future<List<BuyerAddress>> getBuyerAddresses(String buyerId) async {
    final rows = await SupabaseService.client
        .from('buyer_addresses')
        .select()
        .eq('buyer_id', buyerId)
        .order('is_default', ascending: false)
        .order('created_at', ascending: true);
    return (rows as List).map((r) => BuyerAddress.fromJson(Map<String, dynamic>.from(r as Map))).toList();
  }

  static Future<BuyerAddress?> getDefaultBuyerAddress(String buyerId) async {
    final row = await SupabaseService.client
        .from('buyer_addresses')
        .select()
        .eq('buyer_id', buyerId)
        .order('is_default', ascending: false)
        .limit(1)
        .maybeSingle();
    return row == null ? null : BuyerAddress.fromJson(Map<String, dynamic>.from(row));
  }

  static Future<BuyerAddress> addBuyerAddress({
    required String buyerId,
    required String label,
    required String address,
    required String landmark,
    required String city,
    required String state,
    double? latitude,
    double? longitude,
    required bool isDefault,
  }) async {
    final existing = await SupabaseService.client.from('buyer_addresses').select('id').eq('buyer_id', buyerId);
    final makeDefault = isDefault || (existing as List).isEmpty;
    if (makeDefault) {
      await SupabaseService.client.from('buyer_addresses').update({'is_default': false}).eq('buyer_id', buyerId);
    }
    final inserted = await SupabaseService.client.from('buyer_addresses').insert({
      'buyer_id': buyerId,
      'label': label,
      'address': address,
      'landmark': landmark,
      'city': city,
      'state': state,
      'latitude': latitude,
      'longitude': longitude,
      'is_default': makeDefault,
    }).select().single();
    return BuyerAddress.fromJson(Map<String, dynamic>.from(inserted));
  }

  static Future<void> setDefaultBuyerAddress(String buyerId, String addressId) async {
    await SupabaseService.client.from('buyer_addresses').update({'is_default': false}).eq('buyer_id', buyerId);
    await SupabaseService.client.from('buyer_addresses').update({'is_default': true}).eq('id', addressId);
  }

  static Future<void> deleteBuyerAddress(String addressId) async {
    await SupabaseService.client.from('buyer_addresses').delete().eq('id', addressId);
  }

  // ---- Live courier rates (checkout) ----

  /// Fetch live Shipbubble courier rates for one vendor + delivery address.
  /// Returns a quote whose [DeliveryQuote.hasCouriers] is false when no courier
  /// covers the route — the caller then falls back to in-chat negotiation.
  static Future<DeliveryQuote> getDeliveryQuotes({
    required String vendorId,
    required String buyerId,
    required String deliveryAddress,
    String? deliveryLandmark,
    String? deliveryCity,
    double? deliveryLatitude,
    double? deliveryLongitude,
    required List<Map<String, dynamic>> items, // [{name, weight, quantity, amount}]
  }) async {
    final response = await SupabaseService.client.functions.invoke(
      'get-delivery-quotes',
      headers: _authHeaders,
      body: {
        'vendor_id': vendorId,
        'buyer_id': buyerId,
        'delivery_address': deliveryAddress,
        'delivery_landmark': deliveryLandmark,
        'delivery_city': deliveryCity,
        'delivery_latitude': deliveryLatitude,
        'delivery_longitude': deliveryLongitude,
        'items': items,
      },
    );

    if (response.status != 200) {
      final data = response.data;
      final msg = data is Map ? (data['error'] ?? 'Failed to get delivery rates') : 'Failed to get delivery rates';
      throw Exception(msg);
    }
    return DeliveryQuote.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  // ---- Vendor "Request Pickup" (book courier when the item is ready) ----

  /// Vendor asks for the courier to come collect a now-packaged order. The
  /// server re-quotes fresh and books; returns { booked, delivery_id?, reason?,
  /// message? }. booked=false with a reason means try again / unavailable.
  static Future<Map<String, dynamic>> requestPickup(String orderId) async {
    final response = await SupabaseService.client.functions.invoke(
      'request-pickup',
      headers: _authHeaders,
      body: {'order_id': orderId},
    );
    final data = response.data;
    if (response.status != 200) {
      throw Exception(data is Map ? (data['message'] ?? data['error'] ?? 'Pickup request failed') : 'Pickup request failed');
    }
    return Map<String, dynamic>.from(data as Map);
  }

  // ---- Tracking ----

  static Future<Delivery?> getDelivery(String deliveryId) async {
    final row = await SupabaseService.client.from('deliveries').select().eq('id', deliveryId).maybeSingle();
    return row == null ? null : Delivery.fromJson(Map<String, dynamic>.from(row));
  }

  static Future<Delivery?> getDeliveryByOrder(String orderId) async {
    final row = await SupabaseService.client
        .from('deliveries')
        .select()
        .eq('order_id', orderId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return row == null ? null : Delivery.fromJson(Map<String, dynamic>.from(row));
  }

  static Future<List<DeliveryTrackingEvent>> getTrackingEvents(String deliveryId) async {
    final rows = await SupabaseService.client
        .from('delivery_tracking')
        .select()
        .eq('delivery_id', deliveryId)
        .order('timestamp', ascending: true);
    return (rows as List).map((r) => DeliveryTrackingEvent.fromJson(Map<String, dynamic>.from(r as Map))).toList();
  }

  // ---- Route + simulated rider position (OpenStreetMap / OSRM) ----

  /// Ordered status steps used for the tracking timeline and rider progress.
  static const List<String> statusSteps = ['pending', 'confirmed', 'picked_up', 'in_transit', 'delivered'];

  /// Fraction of the route the (simulated) rider has covered for a given status.
  static double progressForStatus(String status) {
    switch (status) {
      case 'confirmed':
        return 0.05;
      case 'picked_up':
        return 0.15;
      case 'in_transit':
        return 0.55;
      case 'delivered':
        return 1.0;
      case 'pending':
      default:
        return 0.0;
    }
  }

  /// Interpolate the rider's position along [route] for the current [status].
  static LatLng riderPosition(List<LatLng> route, String status) {
    if (route.isEmpty) return const LatLng(0, 0);
    if (route.length == 1) return route.first;
    final progress = progressForStatus(status).clamp(0.0, 1.0);
    final index = (route.length * progress).round().clamp(0, route.length - 1);
    return route[index];
  }

  /// Fetch a road route between two points from OSRM (free, no key). Falls back
  /// to a straight two-point line if routing fails or coordinates are missing.
  static Future<List<LatLng>> getRoute({
    required double? fromLat,
    required double? fromLng,
    required double? toLat,
    required double? toLng,
  }) async {
    if (fromLat == null || fromLng == null || toLat == null || toLng == null) {
      return const [];
    }
    final straight = [LatLng(fromLat, fromLng), LatLng(toLat, toLng)];
    try {
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '$fromLng,$fromLat;$toLng,$toLat?overview=full&geometries=geojson',
      );
      final res = await http.get(uri, headers: {'User-Agent': 'DispatchPH/1.0'}).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return straight;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return straight;
      final coords = (routes.first['geometry']['coordinates'] as List)
          .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .toList();
      return coords.isEmpty ? straight : coords;
    } catch (_) {
      return straight;
    }
  }
}
