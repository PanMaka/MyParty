import 'package:flutter/widgets.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../data/device_repository.dart';

/// Reads the handset's IANA zone name ("Europe/Athens", "America/New_York").
/// A seam so tests can say which zone the "device" is in.
typedef DeviceTimezone = Future<String> Function();

Future<String> platformTimezone() async => (await FlutterTimezone.getLocalTimezone()).identifier;

/// Keeps `profiles.notification_tz` equal to the zone the phone is in.
///
/// Quiet hours are wall-clock times, and `in_quiet_hours` reads them in this
/// zone. Until Phase 43 nothing wrote the column, so every user's quiet hours
/// ran on its default, Europe/Athens: "23:00 to 08:00" for someone in London
/// started at 21:00 their time. There is no UI for it on purpose. A zone the
/// user picks by hand is a zone they forget to change when they travel.
///
/// Written on sign-in and again on every resume, which is the closest Flutter
/// gets to "when it changes": the app cannot run while the phone crosses a
/// border, and the OS does not tell a backgrounded app its zone moved. A write
/// happens only when the zone differs from the last value the server is known
/// to hold, so an ordinary resume costs one platform call and no network.
///
/// Never throws. `validate_notification_tz` refuses a name Postgres does not
/// know (22023), and a phone reporting one must not break sign-in. The column
/// then keeps its previous value, which is the best answer available.
class TimezoneSync with WidgetsBindingObserver {
  TimezoneSync({DeviceRepository? devices, DeviceTimezone? deviceTimezone})
      : _devicesOverride = devices,
        _deviceTimezone = deviceTimezone ?? platformTimezone;

  final DeviceRepository? _devicesOverride;
  final DeviceTimezone _deviceTimezone;

  /// Lazy for the same reason the repositories resolve their client lazily:
  /// [Notifications] holds one of these in a static, and constructing a
  /// repository must not need an initialised Supabase.
  late final DeviceRepository _devices = _devicesOverride ?? DeviceRepository();

  /// What the server holds, as far as this instance knows. Null means unknown,
  /// so the next [sync] writes.
  String? _stored;

  bool _observing = false;
  Future<void>? _inFlight;

  /// [storedZone] is the `notification_tz` the sign-in read already fetched,
  /// so the common case (same phone, same zone) writes nothing.
  Future<void> onSignedIn({required String? storedZone}) {
    _stored = storedZone;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    return sync();
  }

  /// Forgets the stored value, so the next account to sign in on this phone
  /// is compared against its own row and not the previous user's, and stops
  /// listening for resumes.
  void onSignOut() {
    _stored = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  /// One at a time: a resume landing while the sign-in sync is still in flight
  /// joins it rather than racing it into a second identical write.
  Future<void> sync() => _inFlight ??= _sync().whenComplete(() => _inFlight = null);

  Future<void> _sync() async {
    try {
      final zone = await _deviceTimezone();
      if (zone.isEmpty || zone == _stored) return;
      await _devices.updatePrefs(timezone: zone);
      _stored = zone;
    } catch (error) {
      debugPrint('[timezone] not synced: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) sync();
  }
}
