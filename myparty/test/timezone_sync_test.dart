import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/device_repository.dart';
import 'package:myparty/services/timezone_sync.dart';

/// Records every `notification_tz` write. Only [updatePrefs] is reached by
/// [TimezoneSync], and it is overridden, so no Supabase client is constructed.
class _FakeDeviceRepository extends DeviceRepository {
  _FakeDeviceRepository({this.refuse = false});

  /// Answers as `validate_notification_tz` does for a name Postgres does not
  /// know.
  final bool refuse;
  final List<String?> timezoneWrites = [];

  @override
  Future<void> updatePrefs({
    bool? notifyNearby,
    int? radiusMeters,
    int? dailyCap,
    String? timezone,
    Duration? quietHoursStart,
    Duration? quietHoursEnd,
    bool clearQuietHours = false,
  }) async {
    timezoneWrites.add(timezone);
    if (refuse) throw Exception('invalid notification_tz: $timezone (22023)');
  }
}

void main() {
  late String deviceZone;
  late _FakeDeviceRepository devices;
  late TimezoneSync sync;

  setUp(() {
    deviceZone = 'Europe/London';
    devices = _FakeDeviceRepository();
    sync = TimezoneSync(devices: devices, deviceTimezone: () async => deviceZone);
  });

  tearDown(() => sync.onSignOut());

  testWidgets('sign-in writes the device zone when the server holds another', (tester) async {
    await sync.onSignedIn(storedZone: 'Europe/Athens');

    expect(devices.timezoneWrites, ['Europe/London']);
  });

  testWidgets('sign-in writes nothing when the zone already matches', (tester) async {
    await sync.onSignedIn(storedZone: 'Europe/London');

    expect(devices.timezoneWrites, isEmpty);
  });

  testWidgets('a resume in a new zone writes it; a resume in the same zone does not', (tester) async {
    await sync.onSignedIn(storedZone: 'Europe/London');

    // Same zone: the ordinary resume, which must cost no network.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(devices.timezoneWrites, isEmpty);

    // The phone landed somewhere else while the app was backgrounded.
    deviceZone = 'America/New_York';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(devices.timezoneWrites, ['America/New_York']);

    // And only once: the next resume compares against what was just written.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(devices.timezoneWrites, ['America/New_York']);
  });

  testWidgets('after sign-out, resumes write nothing', (tester) async {
    await sync.onSignedIn(storedZone: 'Europe/London');
    sync.onSignOut();

    deviceZone = 'Asia/Tokyo';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(devices.timezoneWrites, isEmpty);
  });

  testWidgets('a zone the server refuses does not throw, and is retried next time', (tester) async {
    devices = _FakeDeviceRepository(refuse: true);
    sync = TimezoneSync(devices: devices, deviceTimezone: () async => deviceZone);

    // Sign-in must survive a phone reporting a name Postgres does not know.
    await sync.onSignedIn(storedZone: 'Europe/Athens');
    expect(devices.timezoneWrites, ['Europe/London']);

    // Not remembered as stored, so the next resume tries again.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(devices.timezoneWrites, ['Europe/London', 'Europe/London']);
  });

  testWidgets('a platform that cannot answer writes nothing and does not throw', (tester) async {
    sync = TimezoneSync(devices: devices, deviceTimezone: () async => throw Exception('no channel'));

    await sync.onSignedIn(storedZone: 'Europe/Athens');

    expect(devices.timezoneWrites, isEmpty);
  });

  testWidgets('two syncs at once share one write', (tester) async {
    await Future.wait([
      sync.onSignedIn(storedZone: 'Europe/Athens'),
      sync.sync(),
    ]);

    expect(devices.timezoneWrites, ['Europe/London']);
  });
}
