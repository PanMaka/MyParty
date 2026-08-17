import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:myparty/data/device_repository.dart';
import 'package:myparty/models/notification_prefs.dart';
import 'package:myparty/services/location_reporter.dart';
import 'package:myparty/services/push_service.dart';
import 'package:myparty/ui/screens/notification_settings_screen.dart';
import 'package:myparty/ui/widgets/location_consent_sheet.dart';

/// Stands in for the real repository. Subclasses rather than implements so it
/// stays in sync with the real constructor, and overrides every method that
/// touches the network — `DeviceRepository` resolves its client lazily, so no
/// Supabase client is ever constructed here.
class _FakeDeviceRepository extends DeviceRepository {
  _FakeDeviceRepository({NotificationPrefs? prefs}) : _prefs = prefs ?? _defaults;

  static const _defaults = NotificationPrefs(
    pushConsent: false,
    locationConsent: false,
    notifyNearby: true,
    radiusMeters: 500,
    dailyCap: 5,
    timezone: 'UTC',
  );

  NotificationPrefs _prefs;

  final List<bool> locationConsentWrites = [];
  final List<bool> pushConsentWrites = [];
  final List<(double lat, double lng)> reportedPoints = [];
  final List<String> unregistered = [];

  @override
  String? get currentUserId => 'me';

  @override
  Future<NotificationPrefs?> fetchPrefs() async => _prefs;

  @override
  Future<void> setLocationConsent(bool granted) async {
    locationConsentWrites.add(granted);
    _prefs = _prefs.copyWith(locationConsent: granted);
  }

  @override
  Future<void> setPushConsent(bool granted) async {
    pushConsentWrites.add(granted);
    _prefs = _prefs.copyWith(pushConsent: granted);
  }

  @override
  Future<String?> registerDevice({
    required String pushToken,
    required String platform,
    double? latitude,
    double? longitude,
  }) async {
    if (latitude != null && longitude != null) {
      // Recorded AFTER the rounding the real method applies, which is the thing
      // under test — the precise fix must never leave the handset.
      reportedPoints.add((DeviceRepository.rounded(latitude), DeviceRepository.rounded(longitude)));
    }
    return 'device-1';
  }

  @override
  Future<void> unregisterDevice(String pushToken) async => unregistered.add(pushToken);

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
    _prefs = _prefs.copyWith(
      notifyNearby: notifyNearby,
      radiusMeters: radiusMeters,
      dailyCap: dailyCap,
      quietHoursStart: quietHoursStart,
      quietHoursEnd: quietHoursEnd,
      clearQuietHours: clearQuietHours,
    );
  }
}

/// Geolocator reaches the OS through a platform channel that does not exist
/// under `flutter test`, so the permission state is driven through the platform
/// interface instead. Only the four members these paths touch are overridden;
/// the rest inherit the base class's UnimplementedError, which is what we want
/// — a test that starts calling something new should fail loudly.
class _FakeGeolocator extends GeolocatorPlatform {
  _FakeGeolocator({
    this.permission = LocationPermission.denied,
    this.afterRequest,
    this.serviceEnabled = true,
  });

  LocationPermission permission;
  final LocationPermission? afterRequest;
  final bool serviceEnabled;

  int requestCount = 0;

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requestCount++;
    if (afterRequest != null) permission = afterRequest!;
    return permission;
  }

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) async => _position;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      const Stream<Position>.empty();

  static final _position = Position(
    latitude: 37.97551234,
    longitude: 23.73489876,
    timestamp: DateTime.utc(2026, 8, 17),
    accuracy: 10,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

class _FakePushService extends PushService {
  int registerCount = 0;
  int unregisterCount = 0;

  @override
  String? get token => 'tok-1';

  @override
  Future<PushAvailability> register() async {
    registerCount++;
    return PushAvailability.available;
  }

  @override
  Future<void> unregister() async => unregisterCount++;
}

class _RecordingReporter extends LocationReporter {
  _RecordingReporter({required super.devices})
      : super(pushToken: () => 'tok-1', platform: 'android');

  final List<bool> consentCalls = [];
  LocationConsentResult result = LocationConsentResult.granted;

  @override
  Future<LocationConsentResult> requestConsent({required bool explanationAccepted}) async {
    consentCalls.add(explanationAccepted);
    return result;
  }
}

void main() {
  late _FakeDeviceRepository devices;

  setUp(() {
    devices = _FakeDeviceRepository();
  });

  LocationReporter reporterWith(_FakeGeolocator geo) {
    GeolocatorPlatform.instance = geo;
    return LocationReporter(
      devices: devices,
      pushToken: () => 'tok-1',
      platform: 'android',
    );
  }

  group('rounding', () {
    // The client rounds as well as the trigger. The trigger is what makes the
    // guarantee true for every writer; this is what keeps the precise value out
    // of the statement text, which a stack running log_statement = 'all' would
    // otherwise write to disk before Postgres ever rounded it.
    test('coordinates are cut to three decimals, the ~100m grid', () {
      expect(DeviceRepository.rounded(37.97551234), 37.976);
      expect(DeviceRepository.rounded(23.73489876), 23.735);
      expect(DeviceRepository.rounded(-0.00049), -0.0);
    });

    test('metresBetween is close enough to drive a 100m threshold', () {
      // ~111m north at this latitude — one hundredth of a degree of latitude is
      // 1.11km, so a thousandth is ~111m.
      final d = DeviceRepository.metresBetween(37.9755, 23.7348, 37.9765, 23.7348);
      expect(d, closeTo(111, 3));
    });
  });

  group('consent ordering', () {
    // The compliance requirement, stated as a test: declining the in-app
    // explanation must mean the OS is never asked. Asking anyway would spend
    // the one prompt Android allows before it goes permanent — and would record
    // a permission the user had just refused to understand.
    test('declining the explanation never reaches the OS prompt', () async {
      final geo = _FakeGeolocator(permission: LocationPermission.denied);
      final reporter = reporterWith(geo);

      final result = await reporter.requestConsent(explanationAccepted: false);

      expect(result, LocationConsentResult.explanationDeclined);
      expect(geo.requestCount, 0, reason: 'the OS prompt must not have been shown');
      expect(devices.locationConsentWrites, isEmpty);
      expect(reporter.isRunning, isFalse);
    });

    test('accepting the explanation then being denied writes no consent', () async {
      final geo = _FakeGeolocator(
        permission: LocationPermission.denied,
        afterRequest: LocationPermission.denied,
      );
      final reporter = reporterWith(geo);

      final result = await reporter.requestConsent(explanationAccepted: true);

      expect(result, LocationConsentResult.permissionDenied);
      expect(geo.requestCount, 1);
      // The flag means "we may store a location". A denied permission means we
      // cannot, so recording consent would leave it claiming something untrue.
      expect(devices.locationConsentWrites, isEmpty);
    });

    test('a permanent denial is reported as such, so the UI offers settings', () async {
      final geo = _FakeGeolocator(
        permission: LocationPermission.denied,
        afterRequest: LocationPermission.deniedForever,
      );

      final result = await reporterWith(geo).requestConsent(explanationAccepted: true);

      expect(result, LocationConsentResult.permissionDeniedForever);
      expect(devices.locationConsentWrites, isEmpty);
    });

    test('location services switched off is not treated as a refusal', () async {
      final geo = _FakeGeolocator(serviceEnabled: false);

      final result = await reporterWith(geo).requestConsent(explanationAccepted: true);

      expect(result, LocationConsentResult.serviceDisabled);
      expect(geo.requestCount, 0);
    });

    test('explanation accepted and permission granted records consent and reports', () async {
      final geo = _FakeGeolocator(permission: LocationPermission.whileInUse);
      final reporter = reporterWith(geo);

      final result = await reporter.requestConsent(explanationAccepted: true);

      expect(result, LocationConsentResult.granted);
      expect(devices.locationConsentWrites, [true]);
      // The first fix goes immediately: the engine is event-driven off device
      // movement, so a device that has never reported is invisible to it.
      expect(devices.reportedPoints, [(37.976, 23.735)]);
    });
  });

  group('revocation', () {
    // The path the feature is most likely to get wrong, because the OS never
    // tells the app. Without it the toggle keeps claiming the feature is on
    // while the last cell sits in user_devices for up to 24 hours, still
    // matchable by the proximity queries.
    test('permission revoked while consent is on clears the consent flag', () async {
      devices = _FakeDeviceRepository(
        prefs: _FakeDeviceRepository._defaults.copyWith(locationConsent: true),
      );
      final reporter = reporterWith(_FakeGeolocator(permission: LocationPermission.denied));

      await reporter.syncPermissionState();

      // Writing false is the mechanism, not the record: a trigger on that column
      // going true→false erases every stored location immediately.
      expect(devices.locationConsentWrites, [false]);
      expect(reporter.isRunning, isFalse);
    });

    test('permission granted in settings does NOT grant consent by itself', () async {
      // Consent is informed agreement to the in-app explanation. Re-deriving it
      // from a permission bit is exactly the shortcut the sheet exists to avoid.
      final reporter = reporterWith(_FakeGeolocator(permission: LocationPermission.always));

      await reporter.syncPermissionState();

      expect(devices.locationConsentWrites, isEmpty);
      expect(reporter.isRunning, isFalse);
    });
  });

  group('push consent', () {
    testWidgets('turning push OFF keeps the device row', (tester) async {
      final push = _FakePushService();

      await tester.pumpWidget(MaterialApp(
        home: NotificationSettingsScreen(
          repository: _FakeDeviceRepository(
            prefs: _FakeDeviceRepository._defaults.copyWith(pushConsent: true),
          )..pushConsentWrites.clear(),
          pushService: push,
          locationReporter: _RecordingReporter(devices: devices),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch).at(0));
      await tester.pumpAndSettle();

      // Withdrawing push consent is not the same act as forgetting the device.
      // The token is still this install's, re-enabling should not have to mint a
      // new one, and the engine already refuses to enqueue while the flag is off
      // — the delivery worker re-checks it at claim time too.
      expect(push.unregisterCount, 0);
    });
  });

  group('consent sheet', () {
    // The sheet is deliberately long — it has four things to say before it
    // asks anything — so in the default 800x600 test viewport its buttons sit
    // below the fold. ensureVisible scrolls to them; tapping without it hits
    // whatever happens to be at those coordinates instead.
    Future<bool?> showAndTap(WidgetTester tester, String label) async {
      Future<bool>? pending;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => pending = showLocationConsentSheet(context),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      return pending;
    }

    testWidgets('states what is collected before anything is asked', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showLocationConsentSheet(context),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Each of these is a promise something in the schema keeps. If the copy
      // stops saying them the sheet has stopped being informed consent.
      expect(find.textContaining('~100 μέτρων'), findsOneWidget);
      expect(find.textContaining('24 ώρες'), findsOneWidget);
      expect(find.textContaining('Δεν τη βλέπει κανένας'), findsOneWidget);
      expect(find.textContaining('διαγράφεται'), findsOneWidget);
    });

    testWidgets('accepting returns true', (tester) async {
      expect(await showAndTap(tester, 'Συμφωνώ, ενεργοποίησέ το'), isTrue);
    });

    testWidgets('declining returns false', (tester) async {
      expect(await showAndTap(tester, 'Όχι τώρα'), isFalse);
    });
  });

  group('settings screen', () {
    testWidgets('turning location on shows the explanation before asking the OS',
        (tester) async {
      final reporter = _RecordingReporter(devices: devices);

      await tester.pumpWidget(MaterialApp(
        home: NotificationSettingsScreen(
          repository: devices,
          pushService: _FakePushService(),
          locationReporter: reporter,
        ),
      ));
      await tester.pumpAndSettle();

      // Two switches: push consent, then location consent.
      await tester.tap(find.byType(Switch).at(1));
      await tester.pump();

      expect(find.textContaining('~100 μέτρων'), findsOneWidget,
          reason: 'the explanation sheet must be on screen before consent is requested');
      expect(reporter.consentCalls, isEmpty,
          reason: 'nothing may be requested while the user is still reading');

      await tester.ensureVisible(find.text('Συμφωνώ, ενεργοποίησέ το'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Συμφωνώ, ενεργοποίησέ το'));
      await tester.pumpAndSettle();

      expect(reporter.consentCalls, [true]);
    });

    testWidgets('declining the sheet passes the refusal through', (tester) async {
      final reporter = _RecordingReporter(devices: devices)
        ..result = LocationConsentResult.explanationDeclined;

      await tester.pumpWidget(MaterialApp(
        home: NotificationSettingsScreen(
          repository: devices,
          pushService: _FakePushService(),
          locationReporter: reporter,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch).at(1));
      await tester.pump();
      await tester.ensureVisible(find.text('Όχι τώρα'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Όχι τώρα'));
      await tester.pumpAndSettle();

      expect(reporter.consentCalls, [false]);
      expect(devices.locationConsentWrites, isEmpty);
    });

    testWidgets('turning push on asks PushService, not the database directly',
        (tester) async {
      final push = _FakePushService();

      await tester.pumpWidget(MaterialApp(
        home: NotificationSettingsScreen(
          repository: devices,
          pushService: push,
          locationReporter: _RecordingReporter(devices: devices),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch).at(0));
      await tester.pumpAndSettle();

      // The flag alone would be a lie: consent without a token is a user who
      // believes they enabled notifications and will never receive one.
      expect(push.registerCount, 1);
    });
  });
}
