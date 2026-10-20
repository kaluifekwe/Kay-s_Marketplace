import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';
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

  /// Optional city ("Lagos" / "Abuja" / "Port Harcourt") used to bias address
  /// suggestions toward the relevant area.
  final String? city;

  const LocationPickerScreen({
    super.key,
    this.initialAddress,
    this.initialLat,
    this.initialLng,
    this.title = 'Select Location',
    this.city,
  });

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final Completer<GoogleMapController> _mapController = Completer<GoogleMapController>();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  static const LatLng _phDefault = LatLng(4.8156, 7.0498); // Port Harcourt
  LatLng _center = _phDefault;
  String _address = '';
  bool _loading = true;
  bool _searching = false;
  List<PlacePrediction> _suggestions = [];
  Timer? _debounce;

  // One session token per search session: reused across keystrokes + the final
  // details lookup, then regenerated. Lets Google bill the search as one unit.
  String _sessionToken = const Uuid().v4();

  // Set when we move the camera ourselves (a search pick, or the locate
  // button). The resulting onCameraIdle must not reverse-geocode over an
  // address the user deliberately chose — a rooftop coordinate often reverses
  // to a Plus Code or an unnamed road, which is worse than what they picked.
  bool _programmaticMove = false;

  // Guards against a slow reverse-geocode landing after a newer one and
  // putting a stale address on screen.
  int _addressRequest = 0;

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
    _searchController.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _moveCamera(LatLng target, double zoom) async {
    _programmaticMove = true;
    final controller = await _mapController.future;
    await controller.animateCamera(CameraUpdate.newLatLngZoom(target, zoom));
  }

  // The map settled. If we drove it there we already know the address; only a
  // drag by the user means "tell me what is under the pin now".
  void _onCameraIdle() {
    if (_programmaticMove) {
      _programmaticMove = false;
      return;
    }
    _updateAddress(_center);
  }

  Future<void> _getCurrentLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      final point = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _center = point;
        _loading = false;
      });
      await _moveCamera(point, 16);
      _updateAddress(point);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _updateAddress(_center);
    }
  }

  Future<void> _updateAddress(LatLng point) async {
    final request = ++_addressRequest;
    final address = await GeocodingService.reverseGeocode(point.latitude, point.longitude);
    if (!mounted || request != _addressRequest) return;
    // A failed lookup leaves the previous address in place. Blanking it, or
    // replacing it with coordinates, would lose an address that was fine.
    if (address == null || address.isEmpty) return;
    setState(() => _address = address);
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 3) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _searching = true);
      try {
        final results = await GeocodingService.autocomplete(
          query,
          sessionToken: _sessionToken,
          city: widget.city,
        );
        if (!mounted) return;
        setState(() => _suggestions = results);
      } catch (_) {
        if (!mounted) return;
        setState(() => _suggestions = []);
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  Future<void> _selectSuggestion(PlacePrediction prediction) async {
    _searchFocus.unfocus();
    setState(() {
      _searching = true;
      _suggestions = [];
      _searchController.text = prediction.description;
    });
    final details = await GeocodingService.details(prediction.placeId, sessionToken: _sessionToken);
    // A details call closes the billing session — start a fresh token next time.
    _sessionToken = const Uuid().v4();
    if (!mounted) return;
    setState(() => _searching = false);
    if (details == null) return;
    final point = LatLng(details.lat, details.lng);
    setState(() {
      _center = point;
      _address = details.address.isNotEmpty ? details.address : prediction.description;
    });
    await _moveCamera(point, 17);
  }

  void _goToCurrentLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      final point = LatLng(pos.latitude, pos.longitude);
      await _moveCamera(point, 16);
      _updateAddress(point);
    } catch (_) {}
  }

  void _confirm() {
    Navigator.pop(
      context,
      LocationPickerResult(address: _address, lat: _center.latitude, lng: _center.longitude),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(icon: const Icon(Icons.my_location), onPressed: _goToCurrentLocation),
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
                hintText: 'Search address (e.g., 12 Aba Rd, PH)',
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
              constraints: const BoxConstraints(maxHeight: 240),
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
                    title: Text(s.primary, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: s.secondary.isEmpty
                        ? null
                        : Text(s.secondary, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => _selectSuggestion(s),
                  );
                },
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      GoogleMap(
                        initialCameraPosition: CameraPosition(target: _center, zoom: 16),
                        onMapCreated: (controller) {
                          if (!_mapController.isCompleted) _mapController.complete(controller);
                        },
                        onCameraMove: (pos) => _center = pos.target,
                        onCameraIdle: _onCameraIdle,
                        myLocationEnabled: true,
                        myLocationButtonEnabled: false,
                        zoomControlsEnabled: false,
                      ),
                      // Fixed centre pin — the map slides under it; the target is
                      // whatever sits beneath this marker when the camera settles.
                      const Padding(
                        padding: EdgeInsets.only(bottom: 40),
                        child: Icon(Icons.location_on, color: AppColors.errorRed, size: 44),
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
                                  _address.isNotEmpty
                                      ? _address
                                      : 'Search above, or move the map to pick a spot',
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
