import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// What every map in the app shares: the tiles, the fallback centre and the
/// device fix. Lifted out of `map_screen.dart` when the host wizard's location
/// picker became the second map, so the CARTO key handling and the
/// best-effort location logic each have one definition.

/// Central Athens — where a map opens when there is no device fix.
const kDefaultMapCentre = LatLng(37.9748, 23.7232);

/// The dark CARTO basemap every map in the app draws on.
TileLayer mpTileLayer() => TileLayer(
      // CARTO serves an "API KEY REQUIRED" placeholder for every tile
      // without `key`. Read guarded: widget tests never load .env.
      urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
          '?key=${dotenv.isInitialized ? dotenv.maybeGet('CARTO_API_KEY') ?? '' : ''}',
      subdomains: const ['a', 'b', 'c', 'd'],
      userAgentPackageName: 'com.myparty.app',
    );

/// The real device fix, and the default for every screen's `locate` seam
/// (`MapScreen.locate`, `LocationPickerScreen.locate`).
///
/// Best-effort by construction: every branch that cannot answer returns null
/// and the map falls back to its default centre. The try/catch is the same
/// promise for the branches that throw instead — a permission revoked while
/// the app was backgrounded, a handset with no location provider. An escaping
/// throw here would leave the screen on its spinner permanently, because the
/// caller clears `_isLoading` on the line after this one. Failing to locate
/// the user is not failing to draw the map.
Future<LatLng?> deviceLocation() async {
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
