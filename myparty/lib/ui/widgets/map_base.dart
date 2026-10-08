import 'dart:async';

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

/// Why [locateDevice] has no point to give. Each one asks the user for a
/// different thing — switch location on, grant it, grant it from Settings
/// because the OS will no longer ask, or just try again — so a single "no
/// fix" would leave the recenter button unable to say which.
enum LocationFailure { servicesOff, denied, deniedForever, unavailable }

/// The device fix, or the reason there is none. Exactly one is set.
class DeviceFix {
  const DeviceFix.at(LatLng this.point) : failure = null;
  const DeviceFix.failed(LocationFailure this.failure) : point = null;

  final LatLng? point;
  final LocationFailure? failure;
}

/// How long a fresh fix may take before the last known one is used instead.
/// Without a bound `getCurrentPosition` can wait indefinitely indoors, which
/// on first open is a map stuck on its spinner and on the recenter button is
/// a tap that never answers.
const _kFixTimeout = Duration(seconds: 10);

/// The real device fix, and the default for `MapScreen.locate`.
///
/// Asks for the permission when it has not been decided yet, so a first tap
/// on the recenter button is also the moment the OS dialog appears. Nothing
/// read here leaves the device: this is the map's own blue dot, not the
/// proximity engine's stored cell, which only `LocationReporter` writes and
/// only behind `showLocationConsentSheet`.
///
/// Never throws. A permission revoked while backgrounded or a handset with no
/// provider lands in the catch as [LocationFailure.unavailable]; an escaping
/// throw would leave the map's first load on its spinner permanently.
Future<DeviceFix> locateDevice() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return const DeviceFix.failed(LocationFailure.servicesOff);
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      return const DeviceFix.failed(LocationFailure.deniedForever);
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      return const DeviceFix.failed(LocationFailure.denied);
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: _kFixTimeout,
        ),
      );
      return DeviceFix.at(LatLng(position.latitude, position.longitude));
    } on TimeoutException {
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) return const DeviceFix.failed(LocationFailure.unavailable);
      return DeviceFix.at(LatLng(last.latitude, last.longitude));
    }
  } catch (e) {
    debugPrint('Location unavailable: $e');
    return const DeviceFix.failed(LocationFailure.unavailable);
  }
}

/// [locateDevice] without the reason, for screens that only need a centre and
/// fall back to [kDefaultMapCentre] either way.
Future<LatLng?> deviceLocation() async => (await locateDevice()).point;

/// Opens wherever the user can undo [failure]: the system location switch,
/// or this app's page in Settings once the OS has stopped asking. Null when
/// there is nowhere to send them — a plain denial is re-asked on the next tap.
Future<void> Function()? locationRemedy(LocationFailure failure) => switch (failure) {
      LocationFailure.servicesOff => () => Geolocator.openLocationSettings(),
      LocationFailure.deniedForever => () => Geolocator.openAppSettings(),
      LocationFailure.denied || LocationFailure.unavailable => null,
    };

/// Where the map should centre itself, or null when there is no fix — the map
/// has a default centre and is fully usable without one.
typedef LocationFix = Future<LatLng?> Function();

/// [LocationFix] with the reason, for a screen that has to tell the user why.
typedef LocationLookup = Future<DeviceFix> Function();
