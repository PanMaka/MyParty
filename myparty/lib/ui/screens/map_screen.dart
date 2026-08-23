import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../data/party_repository.dart';
import '../../data/social_repository.dart';
import '../../models/map_party_pin.dart';
import '../../models/map_time_window.dart';
import '../theme/app_theme.dart';
import '../widgets/map_pin_sheet.dart';
import '../widgets/mp_map_pin.dart';
import 'search_screen.dart';

/// The real device fix, and the default for [MapScreen.locate].
///
/// Best-effort by construction: every branch that cannot answer returns null
/// and the map falls back to its default centre. The try/catch is the same
/// promise for the branches that throw instead — a permission revoked while
/// the app was backgrounded, a handset with no location provider. An escaping
/// throw here would leave the screen on its spinner permanently, because the
/// caller clears `_isLoading` on the line after this one. Failing to locate
/// the user is not failing to draw the map.
Future<LatLng?> _deviceLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return null;
    }
    if (permission == LocationPermission.deniedForever) return null;

    final position = await Geolocator.getCurrentPosition();
    return LatLng(position.latitude, position.longitude);
  } catch (e) {
    debugPrint('Location unavailable, falling back to the default centre: $e');
    return null;
  }
}

/// Where the map should centre itself, or null when there is no fix — the map
/// has a default centre and is fully usable without one.
typedef LocationFix = Future<LatLng?> Function();

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.repository, this.social, this.locate});

  /// Injectable so widget tests can subclass [PartyRepository] without a
  /// Supabase client ever existing, the same way [ProfileScreen] takes one.
  /// This screen used to call `Supabase.instance.client.rpc` inline, which is
  /// precisely why it was the one screen with no test.
  final PartyRepository? repository;

  /// Only ever handed to [SearchScreen], which the map opens. The map itself
  /// reads no social data; carrying the seam through keeps the search screen
  /// testable from a map test without a Supabase client existing.
  final SocialRepository? social;

  /// Injectable for a sharper reason than the repository is, and the seam is
  /// not optional: geolocator's platform channel never completes inside
  /// `testWidgets`' fake-async zone. It does not throw — it hangs — so the
  /// try/catch in [_deviceLocation] cannot rescue a test, and any widget test
  /// of this screen would sit on the loading spinner until it timed out.
  /// Measured, not assumed: the same call resolves to a MissingPluginException
  /// immediately under a plain `test()`.
  final LocationFix? locate;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  late final PartyRepository _repository = widget.repository ?? PartyRepository();
  Timer? _debounce;
  LatLng? _currentPosition;
  List<MapPartyPin> _pins = [];
  bool _isLoading = true;
  /// The active time chip. [MapTimeWindow.all] rather than "now": the map's
  /// job on open is to show what exists, and a default that hides most of it
  /// is a filter the user never chose. It is also what makes this change
  /// incapable of removing a pin from anyone's map until they tap something.
  MapTimeWindow _filter = MapTimeWindow.all;

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  Future<void> _initializeMap() async {
    _currentPosition = await (widget.locate ?? _deviceLocation)();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _fetchEventsInBounds() async {
    final center = _mapController.camera.center;
    final bounds = _mapController.camera.visibleBounds;
    const distance = Distance();
    final radiusInMeters = distance.as(LengthUnit.Meter, center, bounds.northEast) * 2.0;

    try {
      final pins = await _repository.fetchPartiesNearUser(
        lon: center.longitude,
        lat: center.latitude,
        radiusMeters: radiusInMeters,
        window: _filter,
      );
      if (mounted) setState(() => _pins = pins);
    } catch (e) {
      debugPrint('Error loading parties: $e');
    }
  }

  void _onPinTap(MapPartyPin pin) => showMapPinSheet(context, pin);

  void _openSearch() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SearchScreen(social: widget.social, parties: widget.repository),
    ));
  }

  /// One pin's marker, sized from the same [now] the pin itself is drawn for.
  ///
  /// The size has to be computed twice — a `Marker` declares its own box and
  /// the pill inside it declares its own extent — but it must not be *derived*
  /// twice: a pin whose tier came from a later clock reading than its box
  /// would be clipped by it. So [MpPinMetrics] answers once here and the same
  /// instant goes down to [MpMapPin], which re-derives from it rather than
  /// from a second `DateTime.now()`.
  Marker _marker(MapPartyPin pin, DateTime now) {
    final metrics = MpPinMetrics.forPin(pin, now);
    return Marker(
      point: LatLng(pin.lat, pin.lng),
      width: metrics.width,
      height: metrics.boxHeight,
      // Not a constant any more. The box is asymmetric — drop on the left,
      // label chip on the right — so the anchor has to name the drop's TIP
      // rather than an edge of the box, and it moves per pin because the chip
      // steps by tier while the drop grows continuously. MpPinMetrics computes
      // it from the same geometry the widget paints, so the two cannot
      // disagree about where the party is.
      alignment: metrics.anchor,
      child: MpMapPin(pin: pin, now: now, onTap: () => _onPinTap(pin)),
    );
  }

  /// The pins in PAINT order: largest first, so the smallest end up on top.
  ///
  /// Drops collide at low zoom and something has to give. The two alternatives
  /// were both worse:
  ///
  /// - **Collision offset** moves a drop off its coordinate, which is the one
  ///   thing the teardrop exists to promise. A pin that lies about where the
  ///   party is fails at the only job a map pin has.
  /// - **Clustering** would count a *distance-truncated* set: the RPC returns
  ///   at most 200 rows ordered by distance, so a cluster badge reading "37"
  ///   would be confidently wrong whenever the cap bit. It also collapses the
  ///   ~50m Syntagma-style clusters this map is built to show.
  ///
  /// Z-order costs one sort and lies about nothing. A large drop can never
  /// fully hide a small one, overlapping bodies still show distinct tips, and
  /// the smaller pin — the harder one to hit — wins the hit test.
  ///
  /// Sorted for PAINTING only. The server's `is_sponsored desc, distance asc`
  /// ordering decides which 200 rows arrive, which is a different question and
  /// is not disturbed by re-ordering them here.
  List<MapPartyPin> _painted(DateTime now) {
    final ordered = [..._pins];
    ordered.sort((a, b) => MpPinMetrics.forPin(b, now)
        .drop
        .radius
        .compareTo(MpPinMetrics.forPin(a, now).drop.radius));
    return ordered;
  }

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
    // The one clock reading every pin on this frame is drawn against. Read
    // here rather than inside each pin so a party crossing its start time
    // cannot be live in one pin's label and not-yet in its own marker box —
    // and re-read on every rebuild rather than stored with the fetch, which
    // is what lets a party go live across the 500ms pan debounce.
    final now = DateTime.now();

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
                  for (final pin in _painted(now)) _marker(pin, now),
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
                // Search is deliberately NOT bounded by the viewport: it opens
                // its own screen and queries every party the viewer may see,
                // wherever it is. Passing the map's centre and radius in here
                // would make "search" mean "search what is on screen", which is
                // a different feature.
                child: GestureDetector(
                  onTap: _openSearch,
                  behavior: HitTestBehavior.opaque,
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
                        Text('Ψάξε πάρτι ή άτομα',
                            style: TextStyle(fontSize: 13.5, color: AppColors.textAlpha(0.5))),
                      ],
                    ),
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
                _filterPill('Όλα', MapTimeWindow.all),
                const SizedBox(width: 7),
                _filterPill('Τώρα', MapTimeWindow.now),
                const SizedBox(width: 7),
                _filterPill('Αργότερα απόψε', MapTimeWindow.tonight),
                const SizedBox(width: 7),
                _filterPill('Το ΣΚ', MapTimeWindow.weekend),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Switches the active chip and refetches.
  ///
  /// The refetch is the whole feature: the window is a parameter to
  /// `get_parties_near_user`, so a new chip is a new query and not a filter
  /// over `_pins`. Narrowing the list in Dart would make "Τώρα" mean "whatever
  /// happened to be in the last viewport fetch" — indistinguishable on a
  /// six-pin test map and wrong everywhere else, because the previous fetch was
  /// capped at 200 rows chosen by distance with no regard for time.
  ///
  /// Re-tapping the active chip is a no-op rather than a toggle back to Όλα:
  /// Όλα is a chip of its own, so a toggle would give two ways to reach one
  /// state and make the pill row's single-selection invariant untrue.
  void _selectFilter(MapTimeWindow value) {
    if (_filter == value) return;
    setState(() => _filter = value);
    _fetchEventsInBounds();
  }

  Widget _filterPill(String label, MapTimeWindow value) {
    final active = _filter == value;
    return GestureDetector(
      onTap: () => _selectFilter(value),
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
            if (value == MapTimeWindow.now) ...[
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
