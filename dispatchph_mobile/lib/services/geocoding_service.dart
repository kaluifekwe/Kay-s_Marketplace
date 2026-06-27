import 'dart:convert';
import 'package:http/http.dart' as http;

class GeocodingService {
  static const String _nominatimBase = 'https://nominatim.openstreetmap.org';

  static Future<List<Map<String, dynamic>>> searchAddress(String query) async {
    final uri = Uri.parse('$_nominatimBase/search?q=${Uri.encodeComponent(query)}&format=json&limit=5&countrycodes=ng');
    final response = await http.get(uri, headers: {'User-Agent': 'DispatchPH/1.0'});
    if (response.statusCode != 200) return [];
    final List data = jsonDecode(response.body);
    return data.map((e) => {
      'display_name': e['display_name'] as String,
      'lat': double.parse(e['lat'] as String),
      'lng': double.parse(e['lon'] as String),
    }).toList();
  }

  static Future<String> reverseGeocode(double lat, double lng) async {
    final uri = Uri.parse('$_nominatimBase/reverse?lat=$lat&lon=$lng&format=json');
    final response = await http.get(uri, headers: {'User-Agent': 'DispatchPH/1.0'});
    if (response.statusCode != 200) return '$lat, $lng';
    final data = jsonDecode(response.body);
    return data['display_name'] as String? ?? '$lat, $lng';
  }
}