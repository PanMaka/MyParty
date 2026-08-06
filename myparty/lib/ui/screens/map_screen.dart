import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/map_party_pin.dart';
import '../theme/app_theme.dart';
import '../widgets/map_pin_sheet.dart';
import '../widgets/mp_map_pin.dart';

enum _MapFilter { live, later, weekend }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  Timer? _debounce;
  LatLng? _currentPosition;
  List<MapPartyPin> _pins = [];
  bool _isLoading = true;
  _MapFilter _filter = _MapFilter.live;

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  Future<void> _initializeMap() async {
    await _getUserLocation();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _getUserLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    final position = await Geolocator.getCurrentPosition();
    _currentPosition = LatLng(position.latitude, position.longitude);
  }

  Future<void> _fetchEventsInBounds() async {
    final center = _mapController.camera.center;
    final bounds = _mapController.camera.visibleBounds;
    const distance = Distance();
    final radiusInMeters = distance.as(LengthUnit.Meter, center, bounds.northEast) * 2.0;

    try {
      final response = await Supabase.instance.client.rpc(
        'get_parties_near_user',
        params: {
          'map_center_lon': center.longitude,
          'map_center_lat': center.latitude,
          'radius_meters': radiusInMeters,
        },
      );

      final pins = <MapPartyPin>[];
      for (var i = 0; i < (response as List).length; i++) {
        final event = response[i] as Map<String, dynamic>;
        if (event['lat'] != null && event['lon'] != null) {
          pins.add(MapPartyPin.fromRpcRow(event, fallbackId: 'pin_$i'));
        }
      }

      if (mounted) setState(() => _pins = pins);
    } catch (e) {
      debugPrint('Error loading parties: $e');
    }
  }

  void _onPinTap(MapPartyPin pin) => showMapPinSheet(context, pin);

  void _recenter() {
    if (_pins.isEmpty) return;
    final points = _pins.map((p) => LatLng(p.lat, p.lng)).toList();
    if (_currentPosition != null) points.add(_currentPosition!);
    _mapController.fitCamera(
      CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.fromLTRB(34, 116, 34, 152)),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(child: CircularProgressIndicator(color: AppColors.purple)),
      );
    }

    final startingPoint = _currentPosition ?? const LatLng(37.9748, 23.7232);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: startingPoint,
              initialZoom: 15,
              onMapReady: _fetchEventsInBounds,
              onPositionChanged: (position, hasGesture) {
                if (_debounce?.isActive ?? false) _debounce!.cancel();
                _debounce = Timer(const Duration(milliseconds: 500), _fetchEventsInBounds);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.myparty.app',
              ),
              MarkerLayer(
                markers: [
                  for (final pin in _pins)
                    Marker(
                      point: LatLng(pin.lat, pin.lng),
                      width: mpPinWidth(pin.attendeeCount),
                      height: mpPinHeight + 6,
                      alignment: Alignment.topCenter,
                      child: MpMapPin(pin: pin, onTap: () => _onPinTap(pin)),
                    ),
                  if (_currentPosition != null)
                    Marker(
                      point: _currentPosition!,
                      width: 22,
                      height: 22,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.text,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.purpleDeep, width: 3),
                          boxShadow: [BoxShadow(color: AppColors.purpleDeep.withValues(alpha: 0.9), blurRadius: 18)],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          _topOverlay(),
          _legend(),
          _recenterButton(),
        ],
      ),
    );
  }

  Widget _topOverlay() {
    return Positioned(
      top: 46,
      left: 14,
      right: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                  decoration: BoxDecoration(
                    color: AppColors.chipFill,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.hairline),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search, size: 16, color: AppColors.textAlpha(0.5)),
                      const SizedBox(width: 8),
                      Text('Ψάξε πάρτι ή μέρος', style: TextStyle(fontSize: 13.5, color: AppColors.textAlpha(0.5))),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.chipFill,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.hairline),
                ),
                child: const Icon(Icons.chat_bubble_outline, size: 18, color: AppColors.text),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _filterPill('Τώρα', _MapFilter.live),
                const SizedBox(width: 7),
                _filterPill('Αργότερα απόψε', _MapFilter.later),
                const SizedBox(width: 7),
                _filterPill('Το ΣΚ', _MapFilter.weekend),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterPill(String label, _MapFilter value) {
    final active = _filter == value;
    return GestureDetector(
      onTap: () => setState(() => _filter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          gradient: active ? AppColors.purpleGradient : null,
          color: active ? null : AppColors.chipFill,
          borderRadius: BorderRadius.circular(99),
          border: active ? null : Border.all(color: AppColors.hairline),
          boxShadow: active ? [BoxShadow(color: AppColors.purpleDeep.withValues(alpha: 0.5), blurRadius: 18)] : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (value == _MapFilter.live) ...[
              Container(width: 6, height: 6, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
              const SizedBox(width: 6),
            ],
            Text(label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? Colors.white : AppColors.textAlpha(0.7),
                )),
          ],
        ),
      ),
    );
  }

  Widget _legend() {
    return Positioned(
      bottom: 104,
      left: 14,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.chipFill,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _legendRow(AppColors.purple, dashed: false, label: 'Δημόσιο · το βλέπουν όλοι'),
            const SizedBox(height: 7),
            _legendRow(AppColors.pink, dashed: true, label: 'Ιδιωτικό · μόνο καλεσμένοι'),
          ],
        ),
      ),
    );
  }

  Widget _legendRow(Color color, {required bool dashed, required String label}) {
    return Row(
      children: [
        Container(
          width: 20,
          height: 14,
          decoration: BoxDecoration(
            color: const Color(0xFF0E0C14).withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(5),
            border: dashed ? null : Border.all(color: color.withValues(alpha: 0.95), width: 1.5),
          ),
        ),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.72))),
      ],
    );
  }

  Widget _recenterButton() {
    return Positioned(
      bottom: 104,
      right: 14,
      child: GestureDetector(
        onTap: _recenter,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.chipFill,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: AppColors.hairline),
          ),
          child: const Icon(Icons.my_location, size: 18, color: AppColors.purple),
        ),
      ),
    );
  }
}
