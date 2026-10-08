import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../data/party_repository.dart';
import '../../data/social_repository.dart';
import '../../models/map_party_pin.dart';
import '../../models/map_time_window.dart';
import '../../state/rsvp_changes.dart';
import '../theme/app_theme.dart';
import '../widgets/map_base.dart';
import '../widgets/map_pin_sheet.dart';
import '../widgets/mp_map_pin.dart';
import 'search_screen.dart';

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
  /// try/catch in [deviceLocation] cannot rescue a test, and any widget test
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

  /// Set by `onMapReady`. Until then the camera has no viewport to read, so a
  /// refetch triggered from outside (an RSVP) has nothing to ask for.
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    rsvpChanges.addListener(_onRsvpChanged);
    _initializeMap();
  }

  /// An RSVP moved a counter on the server — from this map's sheet, a search
  /// hit's, or the Parties tab — so the pin sizes and labels are stale.
  ///
  /// Patched first, so the number on the drop moves the moment the write
  /// lands, then refetched, because the server's counters are the truth (and
  /// include anyone else who answered meanwhile). [MapPartyPin.withRsvp] reads
  /// the delta off THIS copy's `my_rsvp_status`, which is still the pre-tap
  /// answer, so it applies the same step the sheet did.
  void _onRsvpChanged() {
    final change = rsvpChanges.value;
    if (change != null && mounted) {
      final index = _pins.indexWhere((p) => p.id == change.partyId);
      if (index >= 0) {
        setState(() {
          _pins = [..._pins]..[index] = _pins[index].withRsvp(change.status?.name);
        });
      }
    }
    if (_mapReady) _fetchEventsInBounds();
  }

  Future<void> _initializeMap() async {
    _currentPosition = await (widget.locate ?? deviceLocation)();
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

  void _onPinTap(MapPartyPin pin) =>
      showMapPinSheet(context, pin, repository: _repository);

  void _openSearch() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SearchScreen(social: widget.social, parties: widget.repository),
    ));
  }

  /// One pin's marker, sized from the same [now] the pin itself is drawn for.
  ///
  /// The size has to be computed twice — a `Marker` declares its own box and
  /// the bubble inside it declares its own extent — but it must not be
  /// *derived* twice: a pin whose size came from a later clock reading than
  /// its box would be clipped by it. So [MpPinMetrics] answers once here and
  /// the same instant goes down to [MpMapPin], which re-derives from it rather
  /// than from a second `DateTime.now()`.
  Marker _marker(MapPartyPin pin, DateTime now) {
    final metrics = MpPinMetrics.forPin(pin, now);
    return Marker(
      point: LatLng(pin.lat, pin.lng),
      width: metrics.width,
      height: metrics.boxHeight,
      // A constant again — `Alignment(0, -1)` — now that the label chip is
      // gone and the box is the bubble exactly. Still read from MpPinMetrics
      // rather than written down here: it is derived from the same geometry
      // the widget paints, so a future shape whose apex is not at the bottom
      // centre moves the anchor with it instead of quietly lying about where
      // the party is.
      alignment: metrics.anchor,
      child: MpMapPin(pin: pin, now: now, onTap: () => _onPinTap(pin)),
    );
  }

  /// The pins in PAINT order: largest first, so the smallest end up on top.
  ///
  /// Bubbles collide at low zoom and something has to give. Stripping the
  /// label took the pin from 112px wide to `2r` — 34px empty, 68px saturated —
  /// so the ~42m Syntagma cluster now separates around z17 instead of z19, and
  /// what is left for this sort to handle is the genuinely dense case. The two
  /// alternatives are still both worse:
  ///
  /// - **Collision offset** moves a drop off its coordinate, which is the one
  ///   thing the teardrop exists to promise. A pin that lies about where the
  ///   party is fails at the only job a map pin has.
  /// - **Clustering** would count a *distance-truncated* set: the RPC returns
  ///   at most 200 rows ordered by distance, so a cluster badge reading "37"
  ///   would be confidently wrong whenever the cap bit. It also collapses the
  ///   ~50m Syntagma-style clusters this map is built to show.
  ///
  /// Z-order costs one sort and lies about nothing, and the narrower pin makes
  /// it stronger rather than redundant: two overlapping bubbles now differ
  /// only in diameter, so the smaller one always shows as a whole disc inside
  /// the gap the larger cannot cover, and it — the harder one to hit — wins
  /// the hit test.
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
    rsvpChanges.removeListener(_onRsvpChanged);
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

    final startingPoint = _currentPosition ?? kDefaultMapCentre;
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
              onMapReady: () {
                _mapReady = true;
                _fetchEventsInBounds();
              },
              onPositionChanged: (position, hasGesture) {
                if (_debounce?.isActive ?? false) _debounce!.cancel();
                _debounce = Timer(const Duration(milliseconds: 500), _fetchEventsInBounds);
              },
            ),
            children: [
              mpTileLayer(),
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
          // Search is deliberately NOT bounded by the viewport: it opens its
          // own screen and queries every party the viewer may see, wherever it
          // is. Passing the map's centre and radius in here would make "search"
          // mean "search what is on screen", which is a different feature.
          GestureDetector(
            onTap: _openSearch,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: double.infinity,
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
                  Text('Search parties or people',
                      style: TextStyle(fontSize: 13.5, color: AppColors.textAlpha(0.5))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _filterPill('All', MapTimeWindow.all),
                const SizedBox(width: 7),
                _filterPill('Live', MapTimeWindow.now),
                const SizedBox(width: 7),
                _filterPill('Later tonight', MapTimeWindow.tonight),
                const SizedBox(width: 7),
                _filterPill('Weekend', MapTimeWindow.weekend),
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
  /// over `_pins`. Narrowing the list in Dart would make "Live" mean "whatever
  /// happened to be in the last viewport fetch" — indistinguishable on a
  /// six-pin test map and wrong everywhere else, because the previous fetch was
  /// capped at 200 rows chosen by distance with no regard for time.
  ///
  /// Re-tapping the active chip is a no-op rather than a toggle back to All:
  /// All is a chip of its own, so a toggle would give two ways to reach one
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
      // ~1cm above the recenter button's baseline (104). The bottom nav is
      // fixed-height and overlays from the screen bottom without reading the
      // safe-area inset, so an offset from the same edge stays clear of it on
      // every device; adding the inset here alone would only desync the legend
      // from the recenter button. Left side, so it never meets that button.
      bottom: 142,
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
            _legendRow(isPrivate: false, label: 'Public · anyone can see it'),
            const SizedBox(height: 7),
            _legendRow(isPrivate: true, label: 'Private · invited only'),
          ],
        ),
      ),
    );
  }

  // Same accent and same solid/dashed split as the pin (MpMapPin), so the
  // legend describes exactly what is drawn. The dashed swatch used to be a
  // fill with no border at all, which is why private read as "dark".
  Widget _legendRow({required bool isPrivate, required String label}) {
    final color = AppColors.partyAccent(isPrivate: isPrivate).withValues(alpha: 0.95);
    return Row(
      children: [
        CustomPaint(
          size: const Size(20, 14),
          painter: _LegendSwatchPainter(color: color, dashed: isPrivate),
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

/// The legend's swatch: a small rounded rect in the pin's dark fill, bordered
/// solid (public) or dashed (private) in the pin's accent. The dash spacing
/// matches MpDropPainter so the two read as the same mark.
class _LegendSwatchPainter extends CustomPainter {
  const _LegendSwatchPainter({required this.color, required this.dashed});

  final Color color;
  final bool dashed;

  static const double _stroke = 1.5;
  static const double _dash = 5;
  static const double _gap = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(_stroke / 2),
      const Radius.circular(5),
    );
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFF0E0C14).withValues(alpha: 0.9));

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..color = color;
    final path = ui.Path()..addRRect(rrect);
    if (!dashed) {
      canvas.drawPath(path, stroke);
      return;
    }
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), stroke);
        distance = next + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_LegendSwatchPainter old) => old.color != color || old.dashed != dashed;
}
