import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:myparty/data/party_repository.dart';
import 'package:myparty/models/map_party_pin.dart';
import 'package:myparty/ui/screens/map_screen.dart';
import 'package:myparty/ui/widgets/mp_map_pin.dart';

/// Stands in for the real repository. Subclasses rather than implements so it
/// stays in sync with the real constructor, and overrides the one method that
/// touches the network — `PartyRepository` resolves its client lazily, so no
/// Supabase client is ever constructed here.
///
/// That this class is possible at all is half the point of the change it
/// tests: the RPC call used to be `Supabase.instance.client.rpc` inside
/// `MapScreen`, which has no seam and cannot run under `flutter test`.
class _FakePartyRepository extends PartyRepository {
  _FakePartyRepository(this.pins);

  final List<MapPartyPin> pins;

  /// Every call the screen made, so the test can assert the screen asked for
  /// the viewport it is actually showing rather than just that pins appeared.
  final List<Map<String, double>> calls = [];

  @override
  Future<List<MapPartyPin>> fetchPartiesNearUser({
    required double lon,
    required double lat,
    required double radiusMeters,
    int limit = 200,
  }) async {
    calls.add({'lon': lon, 'lat': lat, 'radiusMeters': radiusMeters, 'limit': limit.toDouble()});
    return pins;
  }
}

/// The map's default centre, which is where it lands whenever there is no
/// location fix. Pins are placed within a few hundred metres of it so
/// flutter_map does not cull them out of the 800x600 test viewport.
const _athens = (lat: 37.9748, lon: 23.7232);

MapPartyPin _pin({
  required String id,
  required String title,
  required DateTime? startsAt,
  DateTime? endsAt,
  int goingCount = 0,
  int interestedCount = 0,
  double latOffset = 0,
  bool isPrivate = false,
}) {
  return MapPartyPin(
    id: id,
    lat: _athens.lat + latOffset,
    lng: _athens.lon,
    title: title,
    isPrivate: isPrivate,
    goingCount: goingCount,
    interestedCount: interestedCount,
    startsAt: startsAt,
    endsAt: endsAt,
  );
}

/// Every pin builds an [MpMapPin], and that widget starts a repeating
/// [AnimationController] in `initState` — for every pin, live or not. The test
/// binding fails a test that ends with a ticker still running, so the tree has
/// to come down before the test does. `pumpAndSettle` is unusable here for the
/// same reason: an infinite animation never settles.
Future<void> _teardown(WidgetTester tester) => tester.pumpWidget(const SizedBox());

/// Mounts the screen with no location fix, which is what a real handset that
/// has refused the permission also reports.
///
/// The injected [MapScreen.locate] is not a convenience: geolocator's platform
/// channel neither completes nor throws inside the fake-async zone
/// `testWidgets` runs in, so the real one would hang here forever and every
/// assertion below would be a timeout against a spinner.
Future<void> _mount(
  WidgetTester tester,
  _FakePartyRepository repository, {
  LatLng? fix,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: MapScreen(repository: repository, locate: () async => fix),
  ));
  // initState -> locate -> setState(_isLoading = false) -> FlutterMap ->
  // onMapReady -> the fetch. Pumped rather than settled: the pins' pulse
  // animation repeats forever, so pumpAndSettle would never return.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('MapPartyPin.fromRpcRow', () {
    // The exact column names get_parties_near_user emits, spelled the way the
    // RPC spells them. This is the regression guard: the previous version read
    // `attendee_count`/`pop`/`population` and `live`/`is_live` behind `??`
    // fallbacks, so it parsed this row without complaint and produced a pin
    // with a count of 0 and live=false. A fallback chain over names the server
    // does not use is a bug that cannot fail loudly.
    Map<String, dynamic> row({
      String startsAt = '2026-08-21T20:00:00+00:00',
      String? endsAt = '2026-08-22T04:00:00+00:00',
    }) {
      return <String, dynamic>{
        'party_id': 'aaaaaaaa-0000-0000-0000-000000000002',
        'title': 'Syntagma Afterparty',
        'description': 'A description the pin does not draw.',
        'starts_at': startsAt,
        'ends_at': endsAt,
        'area': 'Κουκάκι',
        'cover_path': 'aaaaaaaa-0000-0000-0000-000000000002/cover.jpg',
        'is_private': false,
        'is_sponsored': false,
        'party_tier': 'standard',
        'host_id': '11111111-1111-1111-1111-111111111111',
        'host_username': 'nikos',
        'lat': 37.9755,
        'lon': 23.7348,
        'distance_meters': 42.5,
        'going_count': 12,
        'interested_count': 34,
        'my_rsvp_status': null,
        'is_invited': false,
      };
    }

    test('reads both counters, both timestamps, the area and the cover key', () {
      final pin = MapPartyPin.fromRpcRow(row(), fallbackId: 'pin_0');

      expect(pin.id, 'aaaaaaaa-0000-0000-0000-000000000002');
      expect(pin.goingCount, 12);
      expect(pin.interestedCount, 34);
      expect(pin.area, 'Κουκάκι');
      expect(pin.coverPath, 'aaaaaaaa-0000-0000-0000-000000000002/cover.jpg');
      expect(pin.hasCover, isTrue);
      expect(pin.startsAt, DateTime.parse('2026-08-21T20:00:00Z').toLocal());
      expect(pin.endsAt, DateTime.parse('2026-08-22T04:00:00Z').toLocal());
    });

    test('a null ends_at parses as null rather than throwing', () {
      // Nullable in the schema and not required by the host wizard, so this is
      // a real row and not a malformed one — see the open `ends_at` decision.
      final pin = MapPartyPin.fromRpcRow(row(endsAt: null), fallbackId: 'pin_0');

      expect(pin.endsAt, isNull);
      expect(pin.startsAt, isNotNull);
    });

    test('an ended party is not live even though the map still returned it', () {
      final pin = MapPartyPin.fromRpcRow(row(), fallbackId: 'pin_0');
      final afterTheEnd = DateTime.parse('2026-08-22T05:00:00Z');

      expect(pin.liveAt(afterTheEnd), isFalse);
      expect(pin.attendeeCountAt(afterTheEnd), 34);
    });
  });

  group('MapPartyPin liveness', () {
    final start = DateTime.parse('2026-08-21T20:00:00Z');
    final end = DateTime.parse('2026-08-22T04:00:00Z');

    // Both sides of each boundary, which is only assertable because liveAt
    // takes the clock instead of reading it.
    test('starts at starts_at and ends at ends_at', () {
      final pin = _pin(id: 'p', title: 'p', startsAt: start, endsAt: end);

      expect(pin.liveAt(start.subtract(const Duration(minutes: 1))), isFalse);
      expect(pin.liveAt(start), isTrue);
      expect(pin.liveAt(end.subtract(const Duration(minutes: 1))), isTrue);
      expect(pin.liveAt(end), isFalse);
    });

    test('a party with no stated end stays live once it has started', () {
      final pin = _pin(id: 'p', title: 'p', startsAt: start);

      expect(pin.liveAt(start.subtract(const Duration(minutes: 1))), isFalse);
      expect(pin.liveAt(start.add(const Duration(days: 30))), isTrue);
    });

    test('the count follows the tense: going while live, interested before', () {
      final pin = _pin(
        id: 'p',
        title: 'p',
        startsAt: start,
        endsAt: end,
        goingCount: 12,
        interestedCount: 34,
      );

      expect(pin.attendeeCountAt(start.subtract(const Duration(hours: 1))), 34);
      expect(pin.attendeeCountAt(start.add(const Duration(hours: 1))), 12);
    });
  });

  group('MapScreen', () {
    testWidgets('draws a pin per row, with the counter that matches its tense', (tester) async {
      final now = DateTime.now();
      final repository = _FakePartyRepository([
        _pin(
          id: 'live',
          title: 'Ταράτσα',
          startsAt: now.subtract(const Duration(hours: 1)),
          endsAt: now.add(const Duration(hours: 3)),
          goingCount: 12,
          interestedCount: 99,
        ),
        _pin(
          id: 'upcoming',
          title: 'Αύριο',
          startsAt: now.add(const Duration(days: 1)),
          endsAt: now.add(const Duration(days: 1, hours: 4)),
          goingCount: 88,
          interestedCount: 34,
          latOffset: 0.001,
        ),
      ]);

      await _mount(tester, repository);

      expect(find.byType(MpMapPin), findsNWidgets(2));
      // The counts that used to be a hardcoded 0 for every pin on the map.
      // Both pins carry both numbers, and each must print the OTHER one from
      // its neighbour — so a pin reading the wrong counter fails here rather
      // than passing by coincidence.
      expect(find.text('12 μέσα'), findsOneWidget);
      expect(find.text('34 ενδ.'), findsOneWidget);
      expect(find.text('99 ενδ.'), findsNothing);
      expect(find.text('88 μέσα'), findsNothing);

      await _teardown(tester);
    });

    testWidgets('pin width scales with the count instead of being uniform', (tester) async {
      final now = DateTime.now();
      final repository = _FakePartyRepository([
        _pin(id: 'small', title: 'Μικρό', startsAt: now.add(const Duration(days: 1)), interestedCount: 1),
        _pin(
          id: 'big',
          title: 'Μεγάλο',
          startsAt: now.add(const Duration(days: 1)),
          interestedCount: 400,
          latOffset: 0.001,
        ),
      ]);

      await _mount(tester, repository);

      final small = tester.getSize(find.ancestor(
        of: find.text('Μικρό'),
        matching: find.byType(MpMapPin),
      ));
      final big = tester.getSize(find.ancestor(
        of: find.text('Μεγάλο'),
        matching: find.byType(MpMapPin),
      ));

      // mpPinWidth is `112 + min(26, sqrt(pop) * 1.9)`, so this is the whole
      // observable range. Every pin was 112 wide before the payload fix,
      // because every count was 0.
      expect(small.width, lessThan(big.width));
      expect(big.width, 112 + 26);

      await _teardown(tester);
    });

    testWidgets('asks the repository for the viewport it is showing', (tester) async {
      final repository = _FakePartyRepository(const []);

      await _mount(tester, repository);

      expect(repository.calls, isNotEmpty);
      final call = repository.calls.first;
      // The default centre, since no location fix is obtainable here.
      expect(call['lat'], closeTo(_athens.lat, 0.0001));
      expect(call['lon'], closeTo(_athens.lon, 0.0001));
      expect(call['radiusMeters'], greaterThan(0));
      // The limit the screen sends must be one the RPC will not clamp: it
      // caps at 500, silently.
      expect(call['limit'], lessThanOrEqualTo(500));

      await _teardown(tester);
    });

    testWidgets('renders the map rather than the spinner when there are no parties', (tester) async {
      // The regression this guards is not the empty list, it is the location
      // lookup: it throws under `flutter test`, and before the try/catch that
      // throw escaped _initializeMap and left _isLoading true forever.
      final repository = _FakePartyRepository(const []);

      await _mount(tester, repository);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(MpMapPin), findsNothing);
      expect(find.text('Ψάξε πάρτι ή μέρος'), findsOneWidget);

      await _teardown(tester);
    });
  });
}
