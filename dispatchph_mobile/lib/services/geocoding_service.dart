import '../core/services/supabase_service.dart';

/// An address suggestion from Google Places Autocomplete.
class PlacePrediction {
  final String placeId;
  final String description; // full text, e.g. "12 Aba Rd, Port Harcourt, Rivers"
  final String primary; // main line, e.g. "12 Aba Rd"
  final String secondary; // context, e.g. "Port Harcourt, Rivers"

  PlacePrediction({
    required this.placeId,
    required this.description,
    required this.primary,
    required this.secondary,
  });
}

/// Resolved coordinates + formatted address for a chosen prediction.
class PlaceDetails {
  final String address;
  final double lat;
  final double lng;

  PlaceDetails({required this.address, required this.lat, required this.lng});
}

/// Address search + geocoding via the `places-proxy` Edge Function (Google
/// Places). The API key stays server-side; we only ever call the proxy.
///
/// [sessionToken] should be a single uuid generated when the user starts
/// typing, reused for every [autocomplete] call and the final [details] call,
/// then discarded — that lets Google bill the search as one session.
class GeocodingService {
  static Future<List<PlacePrediction>> autocomplete(
    String input, {
    required String sessionToken,
    String? city,
  }) async {
    final res = await SupabaseService.client.functions.invoke('places-proxy', body: {
      'action': 'autocomplete',
      'input': input,
      'sessionToken': sessionToken,
      'city': ?city,
    });
    final data = res.data;
    final list = (data is Map && data['predictions'] is List) ? data['predictions'] as List : const [];
    return list
        .map((e) => PlacePrediction(
              placeId: e['place_id'] as String? ?? '',
              description: e['description'] as String? ?? '',
              primary: e['primary'] as String? ?? '',
              secondary: e['secondary'] as String? ?? '',
            ))
        .where((p) => p.placeId.isNotEmpty)
        .toList();
  }

  static Future<PlaceDetails?> details(String placeId, {required String sessionToken}) async {
    final res = await SupabaseService.client.functions.invoke('places-proxy', body: {
      'action': 'details',
      'placeId': placeId,
      'sessionToken': sessionToken,
    });
    final data = res.data;
    if (data is! Map || data['lat'] == null || data['lng'] == null) return null;
    return PlaceDetails(
      address: data['address'] as String? ?? '',
      lat: (data['lat'] as num).toDouble(),
      lng: (data['lng'] as num).toDouble(),
    );
  }

  /// Coordinates -> formatted address, or null if the lookup failed.
  ///
  /// Returns null rather than a "4.8156, 7.0498" string: raw coordinates are
  /// not an address a courier can deliver to, and showing them makes a broken
  /// lookup look like a successful one. Callers should keep whatever address
  /// they already have instead.
  static Future<String?> reverseGeocode(double lat, double lng) async {
    try {
      final res = await SupabaseService.client.functions.invoke('places-proxy', body: {
        'action': 'reverse',
        'lat': lat,
        'lng': lng,
      });
      final data = res.data;
      if (data is Map && data['address'] is String) {
        final address = data['address'] as String;
        if (address.trim().isNotEmpty) return address;
      }
    } catch (_) {
      // Most often the Geocoding API is not enabled on the server key — it is a
      // separate API from Places, so search can work while this does not.
    }
    return null;
  }
}
