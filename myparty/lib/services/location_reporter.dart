import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

import '../data/device_repository.dart';

/// What came of asking to use this person's location.
enum LocationConsentResult {
  /// In-app explanation accepted, OS permission granted, consent recorded.
  granted,

  /// The user read the explanation and said no. The OS prompt was never shown —
  /// which is the point of showing the explanation first, since a declined OS
  /// prompt on Android can only be asked again once, and on iOS never.
  explanationDeclined,

  /// The OS prompt was shown and refused. Askable again later.
  permissionDenied,

  /// Refused permanently, or refused twice on Android. Only the system settings
  /// app can undo this, so the UI must offer that rather than re-prompting.
  permissionDeniedForever,

  /// Location services are switched off device-wide. Not a refusal, and not
  /// something this app can fix.
  serviceDisabled,
}

/// Collects the ~100m cell this device is in and keeps `user_devices` up to
/// date, so the proximity engine has something to match against.
///
/// THE ORDER OF OPERATIONS IN [requestConsent] IS A COMPLIANCE REQUIREMENT, not
/// a UX preference. The in-app explanation of what is collected and why is shown
/// **before** the OS permission dialog, never after and never merged into it: a
/// bare system prompt gives the user no way to know that what is stored is a
/// rounded cell, held for 24 hours, and visible to nobody. Consent that
/// uninformed is not consent.
///
/// `profiles.location_consent` is written true only when BOTH the explanation
/// was accepted and the OS granted permission. Recording it earlier would leave
/// the flag claiming a permission the app does not have.
class LocationReporter with WidgetsBindingObserver {
  LocationReporter({
    DeviceRepository? devices,
    required String? Function() pushToken,
    required String platform,
  })  : _devices = devices ?? DeviceRepository(),
        // prefer_initializing_formals cannot be satisfied here: the fields are
        // private, and Dart has no private NAMED parameters, so `required
        // this._pushToken` is not expressible.
        // ignore: prefer_initializing_formals
        _pushToken = pushToken,
        // ignore: prefer_initializing_formals
        _platform = platform;

  final DeviceRepository _devices;
  final String? Function() _pushToken;
  final String _platform;

  StreamSubscription<Position>? _positions;
  double? _lastSentLat;
  double? _lastSentLng;

  /// Matches `round_location`'s grid. Reporting more often than the cell can
  /// change is pure battery and network cost for a value the database would
  /// round to the same point — and every suppressed report is one less
  /// coordinate leaving the handset.
  static const _minMovementMetres = 100.0;

  bool get isRunning => _positions != null;

  /// Called after the in-app explanation has been shown and accepted.
  ///
  /// [explanationAccepted] is passed in rather than decided here so this class
  /// stays free of UI — but it is required, and passing `true` without having
  /// shown the sheet is the one misuse that would break the compliance
  /// guarantee. `showLocationConsentSheet` is the only intended caller.
  Future<LocationConsentResult> requestConsent({required bool explanationAccepted}) async {
    if (!explanationAccepted) return LocationConsentResult.explanationDeclined;

    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationConsentResult.serviceDisabled;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      return LocationConsentResult.permissionDeniedForever;
    }
    if (permission == LocationPermission.denied) {
      return LocationConsentResult.permissionDenied;
    }

    // Granted — `whileInUse` or `always`. Both are accepted: Android will not
    // offer background location until while-in-use has been granted and the app
    // has been used, so demanding `always` up front would fail on every device
    // and teach the user to refuse. Foreground reporting already satisfies the
    // feature; background is an upgrade the settings screen can ask for later.
    await _devices.setLocationConsent(true);
    await start();
    return LocationConsentResult.granted;
  }

  /// Begins reporting. Idempotent.
  Future<void> start() async {
    if (_positions != null) return;
    if (!await _hasPermission()) return;

    // One immediate fix, so a user who just granted permission is matchable now
    // rather than after their next hundred metres. The proximity engine is
    // event-driven off device movement, and a device that has never reported is
    // invisible to it.
    try {
      final first = await Geolocator.getCurrentPosition();
      await _report(first);
    } catch (error) {
      debugPrint('[location] initial fix failed: $error');
    }

    _positions = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        // The OS does the first round of filtering, so most fixes never reach
        // Dart at all. `_report` filters again, because this is a hint on some
        // platforms rather than a guarantee.
        distanceFilter: 100,
      ),
    ).listen(_report, onError: (Object error) {
      debugPrint('[location] stream error: $error');
    });
  }

  Future<void> stop() async {
    await _positions?.cancel();
    _positions = null;
    _lastSentLat = null;
    _lastSentLng = null;
  }

  Future<bool> _hasPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  Future<void> _report(Position position) async {
    final token = _pushToken();
    // A location is stored against a device row, and the token is that row's
    // key. No token means no row to attach it to — which is the ordinary state
    // on a handset where push is unavailable, not an error.
    if (token == null) return;

    if (_lastSentLat != null &&
        DeviceRepository.metresBetween(
              _lastSentLat!, _lastSentLng!, position.latitude, position.longitude,
            ) <
            _minMovementMetres) {
      return;
    }

    try {
      await _devices.reportLocation(
        pushToken: token,
        platform: _platform,
        latitude: position.latitude,
        longitude: position.longitude,
      );
      _lastSentLat = position.latitude;
      _lastSentLng = position.longitude;
    } on DeviceRegistrationException catch (error) {
      // Consent was withdrawn out from under us — from another device, or by
      // the revocation path below racing this report. The write was refused,
      // which is the system working; stop rather than retry.
      if (error.problem == DeviceRegistrationProblem.locationConsentMissing) {
        await stop();
      }
      debugPrint('[location] report refused: ${error.problem}');
    }
  }

  /// Re-checks the OS permission whenever the app comes back to the foreground,
  /// and handles the case the feature is most likely to get wrong.
  ///
  /// A user can revoke location permission in the system settings at any time,
  /// and the app is never told. Without this, `location_consent` stays true, the
  /// UI keeps claiming the feature is on, and — the part that actually matters —
  /// the last stored cell sits in `user_devices` for up to 24 hours, still
  /// matchable by the proximity queries, for someone who has plainly withdrawn
  /// permission.
  ///
  /// Writing `location_consent = false` is what fixes that, and it does more
  /// than record a fact: a trigger on that column going true→false erases every
  /// stored location for the user immediately (GDPR Art. 7(3)). Merely stopping
  /// the stream would leave the data behind.
  ///
  /// The push token and the device row survive. Revoking location permission is
  /// not unsubscribing from notifications.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(syncPermissionState());
  }

  Future<void> syncPermissionState() async {
    final prefs = await _devices.fetchPrefs();
    if (prefs == null) return;

    final permitted = await _hasPermission();

    if (prefs.locationConsent && !permitted) {
      await stop();
      await _devices.setLocationConsent(false);
      return;
    }

    // The other direction: permission granted in system settings while consent
    // is still false. NOT treated as consent — the OS dialog is not the informed
    // explanation, and re-deriving consent from a permission bit is exactly the
    // shortcut this class exists to avoid. Reporting stays off until the user
    // passes through the explanation again.
    if (prefs.locationConsent && permitted && !isRunning) {
      await start();
    }
  }
}
