import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme/app_theme.dart';
import '../widgets/map_base.dart';

/// Full-screen map for putting a party's pin exactly where the party is.
///
/// Pops with the chosen [LatLng], or with nothing when the host backs out.
///
/// The pin is FIXED at the centre and the map moves under it, rather than the
/// pin following a tap. A dragged pin sits under the finger that is placing
/// it, which is the one moment the host most needs to see what is beneath it;
/// a fixed centre pin never is. A tap still works, by moving the map so the
/// tapped point lands under the pin.
///
/// No geocoding, in either direction, and that is a decision rather than a
/// missing feature: turning an address into a point, or a point into an
/// address, means sending it to a third-party service, and a private party's
/// location is the value this schema is most careful with (see the comment
/// on `parties.area`). The host looks at the map and decides.
class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key, this.initial, this.locate});

  /// A point picked earlier. When set the map opens on it and [locate] is not
  /// called — the host is adjusting their own choice, not starting over.
  final LatLng? initial;

  /// Same seam as [MapScreen.locate], for the same reason: geolocator never
  /// completes inside `testWidgets`, so tests must hand in a fix.
  final LocationFix? locate;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final MapController _controller = MapController();

  /// The point under the pin. Tracked from the camera rather than read from
  /// the controller at confirm time only, so the coordinates on screen are
  /// always the ones "Use this spot" will return.
  late LatLng _centre;

  LatLng? _startingPoint;
  bool _locating = false;

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

  Future<void> _locate() async {
    final fix = await (widget.locate ?? deviceLocation)();
    if (!mounted) return;
    setState(() {
      _startingPoint = fix ?? kDefaultMapCentre;
      _centre = _startingPoint!;
      _locating = false;
    });
  }

  Future<void> _recenter() async {
    final fix = await (widget.locate ?? deviceLocation)();
    if (!mounted || fix == null) return;
    _controller.move(fix, _controller.camera.zoom);
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
                    onPositionChanged: (camera, _) => setState(() => _centre = camera.center),
                    onTap: (_, point) => _controller.move(point, _controller.camera.zoom),
                  ),
                  children: [mpTileLayer()],
                ),
                const IgnorePointer(child: Center(child: _CentrePin())),
                _topBar(),
                _recenterButton(),
                _bottomPanel(),
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
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
            decoration: BoxDecoration(
              color: AppColors.sheet.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Pick the spot', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                      SizedBox(height: 1),
                      Text(
                        'Move the map until the pin sits on the party.',
                        style: TextStyle(fontSize: 11.5, height: 1.3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _recenterButton() {
    return Positioned(
      right: 14,
      bottom: 150,
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
                formatPickedPoint(_centre),
                textAlign: TextAlign.center,
                style: AppTextStyles.mono(size: 12, color: AppColors.textAlpha(0.6)),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                key: const Key('location-picker-confirm'),
                onTap: () => Navigator.of(context).pop(_centre),
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

/// The pin, drawn so its TIP — not its middle — is on the exact centre of the
/// map: the icon is lifted by half its height, and a small dot marks the point
/// itself.
class _CentrePin extends StatelessWidget {
  const _CentrePin();

  static const double _size = 46;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size * 2,
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
            offset: const Offset(0, -_size / 2),
            child: const Icon(
              Icons.location_on,
              size: _size,
              color: AppColors.purple,
              shadows: [Shadow(color: Colors.black54, blurRadius: 10)],
            ),
          ),
        ],
      ),
    );
  }
}
