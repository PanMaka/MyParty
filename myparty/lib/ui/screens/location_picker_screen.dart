import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../services/geocoding_service.dart';
import '../theme/app_theme.dart';
import '../widgets/address_suggestions.dart';
import '../widgets/basemap.dart';
import '../widgets/map_base.dart';

/// What [LocationPickerScreen] pops with: the point under the pin, and the
/// search result the host chose IF the map has not moved since — so the
/// wizard can use that label instead of asking MapTiler again for an address
/// it already has.
@immutable
class PickedSpot {
  const PickedSpot(this.point, {this.place});

  /// The pin. Always this, never [place]'s point, is the party's location.
  final LatLng point;
  final GeocodedPlace? place;
}

/// Full-screen map for putting a party's pin exactly where the party is.
///
/// Pops with a [PickedSpot], or with nothing when the host backs out.
///
/// The pin is FIXED at the centre and the map moves under it, rather than the
/// pin following a tap. A dragged pin sits under the finger that is placing
/// it, which is the one moment the host most needs to see what is beneath it;
/// a fixed centre pin never is. A tap still works, by moving the map so the
/// tapped point lands under the pin. Kept on purpose in Phase 42.
///
/// The search bar (MapTiler, Phase 42 — docs/backlog.md §3) is a way to get
/// the map to the right street; it never sets the location by itself. The
/// pin is still where the host leaves the map.
///
/// No silent default: with no point given and no device fix, the map opens
/// on [kDefaultMapCentre] and "Use this spot" stays off until the host has
/// searched, dragged, tapped or recentred — so central Athens is never a
/// party's location because nobody moved.
class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key, this.initial, this.locate, this.geocoder});

  /// A point picked earlier. When set the map opens on it and [locate] is not
  /// called — the host is adjusting their own choice, not starting over.
  final LatLng? initial;

  /// Same seam as [MapScreen.locate], for the same reason: geolocator never
  /// completes inside `testWidgets`, so tests must hand in a fix.
  final LocationFix? locate;

  /// Address search. Defaults to the real MapTiler service, which without a
  /// key answers "unavailable" and leaves the map fully usable.
  final GeocodingService? geocoder;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final MapController _controller = MapController();
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  late final GeocodeSearchController _search = GeocodeSearchController(
    service: widget.geocoder ?? GeocodingService(),
    // Biased to what the host is looking at, which follows them as they pan.
    near: () async => _centre,
  );

  /// The point under the pin. Tracked from the camera rather than read from
  /// the controller at confirm time only, so the coordinates on screen are
  /// always the ones "Use this spot" will return.
  late LatLng _centre;

  LatLng? _startingPoint;
  bool _locating = false;

  /// True while the map shows the no-fix fallback and the host has not moved
  /// it: the one state "Use this spot" refuses.
  bool _onFallback = false;

  /// The search result the map was moved to, until the map moves again.
  GeocodedPlace? _chosen;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) {
      _startingPoint = widget.initial;
      _centre = widget.initial!;
    } else {
      _locating = true;
      _locate();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    final fix = await (widget.locate ?? deviceLocation)();
    if (!mounted) return;
    setState(() {
      _onFallback = fix == null;
      _startingPoint = fix ?? kDefaultMapCentre;
      _centre = _startingPoint!;
      _locating = false;
    });
  }

  Future<void> _recenter() async {
    final fix = await (widget.locate ?? deviceLocation)();
    if (!mounted || fix == null) return;
    _controller.move(fix, _controller.camera.zoom);
    setState(() {
      _onFallback = false;
      _chosen = null;
    });
  }

  void _choose(GeocodedPlace place) {
    _search.clear();
    _queryFocus.unfocus();
    _query.text = place.label;
    _controller.move(place.point, 17);
    setState(() {
      _centre = place.point;
      _chosen = place;
      _onFallback = false;
    });
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    setState(() {
      _centre = camera.center;
      // Only the host's own gestures count. A programmatic move (a chosen
      // suggestion, the recenter button) reports hasGesture = false.
      if (hasGesture) {
        _onFallback = false;
        _chosen = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: _locating
          ? const Center(child: CircularProgressIndicator(color: AppColors.purple))
          : Stack(
              children: [
                FlutterMap(
                  mapController: _controller,
                  options: MapOptions(
                    initialCenter: _startingPoint!,
                    initialZoom: 17,
                    maxZoom: kBasemapMaxZoom,
                    backgroundColor: kBasemapBackground,
                    onPositionChanged: _onPositionChanged,
                    onTap: (_, point) {
                      _queryFocus.unfocus();
                      _controller.move(point, _controller.camera.zoom);
                      setState(() {
                        _onFallback = false;
                        _chosen = null;
                      });
                    },
                  ),
                  children: const [
                    MpBasemap(),
                    // Above the recenter button (bottom 190, 44 tall), the one
                    // thing on this side of the map clear of the bottom panel.
                    MpBasemapAttribution(bottom: 242),
                  ],
                ),
                const IgnorePointer(child: Center(child: PartyPinMarker())),
                _recenterButton(),
                _bottomPanel(),
                _topBar(),
              ],
            ),
    );
  }

  Widget _topBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
                decoration: BoxDecoration(
                  color: AppColors.sheet.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.hairline),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: TextField(
                        key: const Key('location-picker-search'),
                        controller: _query,
                        focusNode: _queryFocus,
                        onChanged: (text) {
                          _search.onQueryChanged(text);
                          setState(() {});
                        },
                        textInputAction: TextInputAction.search,
                        inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\n\r]'))],
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: 'Search an address or place',
                          hintStyle: TextStyle(fontSize: 14.5, color: AppColors.textAlpha(0.35)),
                        ),
                      ),
                    ),
                    if (_query.text.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          _query.clear();
                          _search.clear();
                          setState(() {});
                        },
                        child: Icon(Icons.close, size: 18, color: AppColors.textAlpha(0.5)),
                      ),
                  ],
                ),
              ),
              AddressSuggestions(controller: _search, onSelected: _choose),
            ],
          ),
        ),
      ),
    );
  }

  Widget _recenterButton() {
    return Positioned(
      right: 14,
      bottom: 190,
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

  Widget _bottomPanel() {
    final canConfirm = !_onFallback;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.sheet.withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _onFallback
                    ? 'Search for the address, or move the map to the party.'
                    : 'Move the map until the pin sits on the party.',
                key: const Key('location-picker-hint'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.3, color: AppColors.textAlpha(0.7)),
              ),
              const SizedBox(height: 4),
              Text(
                formatPickedPoint(_centre),
                textAlign: TextAlign.center,
                style: AppTextStyles.mono(size: 12, color: AppColors.textAlpha(0.6)),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                key: const Key('location-picker-confirm'),
                onTap: canConfirm
                    ? () => Navigator.of(context).pop(PickedSpot(_centre, place: _chosen))
                    : null,
                child: Opacity(
                  opacity: canConfirm ? 1 : 0.4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      gradient: AppColors.purpleGradient,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Center(
                      child: Text('Use this spot', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ),
              ),
              const GeocodeAttribution(),
            ],
          ),
        ),
      ),
    );
  }
}

/// "37.97480, 23.72320" — five decimals is about a metre, which is the
/// precision the pin is actually placed with, so the label does not imply
/// more or less than that.
String formatPickedPoint(LatLng point) =>
    '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';

/// The pin, drawn so its TIP — not its middle — is on the exact centre of
/// whatever it is centred in: the icon is lifted by half its height, and a
/// small dot marks the point itself. The picker and the wizard's preview.
class PartyPinMarker extends StatelessWidget {
  const PartyPinMarker({super.key, this.size = 46});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * 2,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: AppColors.text,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.purpleDeep, width: 2),
            ),
          ),
          Transform.translate(
            offset: Offset(0, -size / 2),
            child: Icon(
              Icons.location_on,
              size: size,
              color: AppColors.purple,
              shadows: const [Shadow(color: Colors.black54, blurRadius: 10)],
            ),
          ),
        ],
      ),
    );
  }
}
