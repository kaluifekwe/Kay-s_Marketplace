import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../../theme/app_theme.dart';
import '../../services/geocoding_service.dart';

class LocationPickerResult {
  final String address;
  final double lat;
  final double lng;

  LocationPickerResult({required this.address, required this.lat, required this.lng});
}

class LocationPickerScreen extends StatefulWidget {
  final String? initialAddress;
  final double? initialLat;
  final double? initialLng;
  final String title;

  const LocationPickerScreen({
    super.key,
    this.initialAddress,
    this.initialLat,
    this.initialLng,
    this.title = 'Select Location',
  });

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  LatLng _center = const LatLng(4.8156, 7.0498); // PH default
  String _address = '';
  bool _loading = true;
  bool _searching = false;
  List<Map<String, dynamic>> _suggestions = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.initialLat != null && widget.initialLng != null) {
      _center = LatLng(widget.initialLat!, widget.initialLng!);
    }
    if (widget.initialAddress != null) {
      _address = widget.initialAddress!;
      _searchController.text = widget.initialAddress!;
    }
    _getCurrentLocation();
  }

  @override
  void dispose() {
    _mapController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _center = LatLng(pos.latitude, pos.longitude);
        _loading = false;
      });
      _mapController.move(_center, 15);
      _updateAddress(_center);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _updateAddress(_center);
    }
  }

  Future<void> _updateAddress(LatLng point) async {
    final address = await GeocodingService.reverseGeocode(point.latitude, point.longitude);
    if (!mounted) return;
    setState(() {
      _address = address;
      _center = point;
    });
  }

  void _onMapMoved() {
    final center = _mapController.camera.center;
    _updateAddress(center);
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.length < 3) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      setState(() => _searching = true);
      final results = await GeocodingService.searchAddress(query);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _suggestions = results;
      });
    });
  }

  void _selectSuggestion(Map<String, dynamic> suggestion) {
    final lat = suggestion['lat'] as double;
    final lng = suggestion['lng'] as double;
    final addr = suggestion['display_name'] as String;
    setState(() {
      _center = LatLng(lat, lng);
      _address = addr;
      _searchController.text = addr;
      _suggestions = [];
    });
    _mapController.move(_center, 16);
    _searchFocus.unfocus();
  }

  void _goToCurrentLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      final point = LatLng(pos.latitude, pos.longitude);
      setState(() => _center = point);
      _mapController.move(point, 15);
      _updateAddress(point);
    } catch (_) {}
  }

  void _confirm() {
    Navigator.pop(context, LocationPickerResult(
      address: _address,
      lat: _center.latitude,
      lng: _center.longitude,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location),
            onPressed: _goToCurrentLocation,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              decoration: InputDecoration(
                hintText: 'Search address (e.g., Mile 4, PH)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _suggestions = []);
                            },
                          )
                        : null,
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          if (_suggestions.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: BoxDecoration(
                color: AppColors.white,
                boxShadow: [BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 4)],
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _suggestions.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final s = _suggestions[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.location_on, size: 18),
                    title: Text(s['display_name'] as String, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => _selectSuggestion(s),
                  );
                },
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _center,
                          initialZoom: 14,
                          onMapEvent: (event) {
                            if (event is MapEventMoveEnd) _onMapMoved();
                          },
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.dispatchph.mobile',
                          ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: _center,
                                child: const Icon(Icons.location_on, color: AppColors.errorRed, size: 40),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Positioned(
                        bottom: 16,
                        left: 16,
                        right: 16,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.white,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [BoxShadow(color: Colors.black.withAlpha(30), blurRadius: 8)],
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _address.isNotEmpty ? _address : 'Move map to select location',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _address.isNotEmpty ? AppColors.charcoal : AppColors.mediumGray,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              ElevatedButton(
                                onPressed: _address.isNotEmpty ? _confirm : null,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primaryGreen,
                                  foregroundColor: AppColors.white,
                                ),
                                child: const Text('Confirm'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}