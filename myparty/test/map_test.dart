import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:myparty/data/party_repository.dart';
import 'package:myparty/models/map_party_pin.dart';
import 'package:myparty/models/map_time_window.dart';
import 'package:myparty/state/mp_store.dart';
import 'package:myparty/state/rsvp_changes.dart';
import 'package:myparty/ui/screens/map_screen.dart';
import 'package:myparty/ui/screens/search_screen.dart';
import 'package:myparty/ui/widgets/map_pin_sheet.dart';
import 'package:myparty/ui/widgets/mp_drop_shape.dart';
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

  /// Cover paths the sheet asked to sign, and what to answer with.
  ///
  /// Overridden rather than left to the real implementation because that one
  /// reaches `_client.storage`, which under `flutter test` has no Supabase
  /// client behind it. A pin with no cover never gets here at all —
  /// `signedCoverUrl` short-circuits on null — which is why the sheet tests
  /// that do not care about covers need no setup.
  final List<String?> signRequests = [];
  String? signedCover;

  @override
  Future<String?> signedCoverUrl(String? coverPath, {int expiresIn = 3600}) async {
    signRequests.add(coverPath);
    if (coverPath == null) return null;
    return signedCover;
  }

  /// The window each of those calls carried, one entry per [calls] entry.
  ///
  /// Kept in a second list rather than added to [calls] because that one is
  /// typed to doubles, and because the assertions it exists for are about the
  /// *sequence* of windows the screen asked for — a chip tap must produce a new
  /// REQUEST, not a narrowing of the rows the last one returned.
  final List<MapTimeWindow> windows = [];

  @override
  Future<List<MapPartyPin>> fetchPartiesNearUser({
    required double lon,
    required double lat,
    required double radiusMeters,
    int limit = 200,
    MapTimeWindow window = MapTimeWindow.all,
  }) async {
    calls.add({'lon': lon, 'lat': lat, 'radiusMeters': radiusMeters, 'limit': limit.toDouble()});
    windows.add(window);
    return pins;
  }

  /// Every RSVP the sheet wrote, and whether the next one should fail.
  final List<({String partyId, MpRsvp status, MpRsvp? current})> rsvpWrites = [];
  bool rsvpFails = false;

  @override
  Future<void> setRsvp({
    required String partyId,
    required MpRsvp status,
    required MpRsvp? current,
  }) async {
    rsvpWrites.add((partyId: partyId, status: status, current: current));
    if (rsvpFails) throw Exception('nope');
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
  int? goingCount = 0,
  int? interestedCount = 0,
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

/// Brings the tree down before the test ends.
///
/// A *live* pin holds a repeating [AnimationController], and the test binding
/// fails a test that ends with a ticker still running. `pumpAndSettle` is
/// unusable for the same reason: an infinite animation never settles. This
/// also unmounts [MapScreen], which cancels its 500ms fetch debounce.
///
/// Non-live pins no longer need this — they hold no ticker at all, which is
/// itself asserted below — but the teardown is cheap and unconditional beats
/// remembering which case is which.
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
  // onMapReady -> the fetch. Pumped rather than settled: a live pin's pulse
  // repeats forever, so pumpAndSettle would never return.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Mounts one pin on its own, for the clock it is drawn against.
///
/// [MpMapPin.now] being a required parameter rather than an internal
/// `DateTime.now()` is what makes this possible: the tests below move a party
/// across its own start and end times without sleeping, and assert what the
/// pin does on each side.
Future<void> _pumpPin(WidgetTester tester, MapPartyPin pin, DateTime now) {
  return tester.pumpWidget(MaterialApp(
    home: Scaffold(body: Center(child: MpMapPin(pin: pin, now: now, onTap: () {}))),
  ));
}

/// The number of frame callbacks currently scheduled, which for this tree is
/// exactly the number of running pulse tickers — nothing else on a bare pin
/// animates. Measured, not assumed: a non-live pin reports 0 and a live one
/// reports 1.
int _runningTickers(WidgetTester tester) => tester.binding.transientCallbackCount;

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

  group('MapPartyPin.withRsvp', () {
    MapPartyPin pin({String? status, bool isPrivate = false}) => MapPartyPin(
          id: 'p',
          lat: 0,
          lng: 0,
          title: 't',
          isPrivate: isPrivate,
          goingCount: isPrivate ? null : 5,
          interestedCount: isPrivate ? null : 20,
          myRsvpStatus: status,
        );

    test('a new going row counts in BOTH, because going implies interested', () {
      final next = pin().withRsvp('going');
      expect((next.goingCount, next.interestedCount, next.myRsvpStatus), (6, 21, 'going'));
    });

    test('a new interested row counts in interested only', () {
      final next = pin().withRsvp('interested');
      expect((next.goingCount, next.interestedCount), (5, 21));
    });

    test('a flip moves going alone, in both directions', () {
      final up = pin(status: 'interested').withRsvp('going');
      expect((up.goingCount, up.interestedCount), (6, 20));
      final down = pin(status: 'going').withRsvp('interested');
      expect((down.goingCount, down.interestedCount), (4, 20));
    });

    test('a withdrawal is the reverse of the matching insert', () {
      final fromGoing = pin(status: 'going').withRsvp(null);
      expect((fromGoing.goingCount, fromGoing.interestedCount, fromGoing.myRsvpStatus), (4, 19, null));
      final fromInterested = pin(status: 'interested').withRsvp(null);
      expect((fromInterested.goingCount, fromInterested.interestedCount), (5, 19));
    });

    test('a private pin keeps null counts -- there is no number to adjust', () {
      final next = pin(isPrivate: true).withRsvp('going');
      expect(next.goingCount, isNull);
      expect(next.interestedCount, isNull);
      expect(next.myRsvpStatus, 'going');
    });
  });

  group('MpPinMetrics', () {
    test('the box is the bubble exactly, with nothing overhanging it', () {
      // The teardrop's box had a `topPad` term because its chip could stand
      // taller than its circle and overhang the top — and since the tip is
      // measured from the box's BOTTOM, forgetting that term moved the anchor
      // on precisely the smallest and most numerous pins. With the chip gone
      // there is no overhang to account for, and this is the assertion that
      // keeps it that way.
      for (final count in [0, 25, 100, 400]) {
        final m = MpPinMetrics.forCount(count);
        expect(m.width, m.drop.width);
        expect(m.height, m.drop.height);
        expect(m.boxHeight, m.drop.height);
      }
    });

    test('width never goes backwards, least of all near saturation', () {
      // Width is now `2r` on a sqrt that saturates, so it is monotonic by
      // construction — which is worth a sweep rather than an argument, because
      // a 25-person party drawing narrower than a 24-person one would read as
      // a smaller party and the failure would be one step in a range nobody
      // looks at.
      var previous = 0.0;
      for (var count = 0; count <= 500; count++) {
        final width = MpPinMetrics.forCount(count).width;
        expect(width, greaterThanOrEqualTo(previous),
            reason: 'width shrank going from ${count - 1} to $count');
        previous = width;
      }
    });

    test('a negative count is drawn as an empty party, not as an error', () {
      expect(MpPinMetrics.forCount(-5).width, MpPinMetrics.forCount(0).width);
    });

    test('the anchor is the bottom centre of the box at every size', () {
      // Constant now that the box is symmetric, but asserted through the
      // geometry rather than against `Alignment.topCenter` — the property that
      // matters is that inverting flutter_map's placement lands on the apex,
      // not that the value happens to be (0, -1) today.
      for (final m in [
        MpPinMetrics.forCount(0),
        MpPinMetrics.forCount(100),
        MpPinMetrics.private(),
      ]) {
        expect(m.tip.dx, closeTo(m.width / 2, 0.001));
        expect(m.tip.dy, closeTo(m.height, 0.001));
        expect(m.anchor.x, closeTo(0, 0.001));
        expect(m.anchor.y, closeTo(-1, 0.001));
      }
    });

    test('the size follows the tense, not a number frozen at fetch time', () {
      // The same pin, the same fetch, two clocks. A party four people are
      // interested in and two hundred turn up to is a small bubble before it
      // starts and a saturated one after — with no refetch, and with no
      // server-computed `live` flag involved.
      final start = DateTime.parse('2026-08-21T20:00:00Z');
      final pin = _pin(
        id: 'p',
        title: 'p',
        startsAt: start,
        endsAt: start.add(const Duration(hours: 8)),
        interestedCount: 4,
        goingCount: 200,
      );

      final before = MpPinMetrics.forPin(pin, start.subtract(const Duration(hours: 1)));
      final during = MpPinMetrics.forPin(pin, start.add(const Duration(hours: 1)));
      final after = MpPinMetrics.forPin(pin, start.add(const Duration(hours: 9)));

      expect(during.width, greaterThan(before.width));
      expect(during.drop.radius, MpDropGeometry.maxRadius);
      // And back down once it is over, because the count reverts to interest.
      expect(after.width, before.width);
    });

    test('a label wide enough to be a problem only lands on a saturated bubble', () {
      // THE INVARIANT THAT REPLACED THE TRUNCATION TEST. The chip needed an
      // ellipsis because its width stepped by tier while the count it drew had
      // no upper bound. Inside the bubble that cannot happen: three digits
      // means a count >= 100, and 100 is exactly where the radius saturates.
      // So every bubble below maximum radius is drawing at most two glyphs,
      // and there is no case left to clip.
      for (var count = 0; count < MpDropGeometry.saturatesAt; count++) {
        expect('$count'.length, lessThanOrEqualTo(2),
            reason: 'a sub-saturation count needs more than two digits');
      }
      for (final count in [100, 999, 4237]) {
        expect(MpPinMetrics.forCount(count).drop.radius, MpDropGeometry.maxRadius,
            reason: 'count $count draws a three- or four-digit label');
      }
    });

    test('the label steps down as it gets wider, so it always fits its circle', () {
      // Measured against the chord available at the text's own height, not
      // against the inscribed square: the number is a single centred line, so
      // the width it actually has is the circle's width at +/- half a line.
      for (final (count, digits) in [(8, 1), (42, 2), (340, 3), (4237, 4)]) {
        final m = MpPinMetrics.forCount(count);
        final r = m.drop.radius;
        final size = MpPinMetrics.labelSizeFor(r, digits);
        // Roboto Mono advances ~0.60em, plus the 0.08em letter-spacing
        // AppTextStyles.mono applies to every glyph.
        final drawn = digits * size * 0.68;
        final available = 2 * math.sqrt(r * r - (size / 2) * (size / 2));
        expect(drawn, lessThan(available),
            reason: 'a $digits-digit label overflows the r=$r bubble');
      }
    });
  });

  group('MpMapPin pulse lifecycle', () {
    final start = DateTime.parse('2026-08-21T20:00:00Z');
    final end = start.add(const Duration(hours: 8));

    testWidgets('a party that has not started holds no ticker at all', (tester) async {
      // The reason this is worth a test rather than a code comment: the pulse
      // is invisible unless the party is live, so a controller running for
      // every pin costs a frame callback each and shows nothing. At the RPC's
      // 200-pin cap that is 200 tickers rebuilding every frame to paint
      // nothing, and no assertion in the suite would have noticed.
      final pin = _pin(id: 'p', title: 'Αύριο', startsAt: start, endsAt: end, interestedCount: 8);

      await _pumpPin(tester, pin, start.subtract(const Duration(hours: 1)));

      expect(_runningTickers(tester), 0);
      await _teardown(tester);
    });

    testWidgets('a live party holds exactly one', (tester) async {
      final pin = _pin(id: 'p', title: 'Τώρα', startsAt: start, endsAt: end, goingCount: 40);

      await _pumpPin(tester, pin, start.add(const Duration(hours: 1)));

      expect(_runningTickers(tester), 1);
      await _teardown(tester);
    });

    testWidgets('a party that starts while its pin is on screen picks one up', (tester) async {
      final pin = _pin(id: 'p', title: 'Σε λίγο', startsAt: start, endsAt: end, goingCount: 40);

      await _pumpPin(tester, pin, start.subtract(const Duration(minutes: 1)));
      expect(_runningTickers(tester), 0);

      // The same pin object, a later clock — which is exactly what a rebuild
      // across the 500ms pan debounce hands the widget.
      await _pumpPin(tester, pin, start.add(const Duration(minutes: 1)));
      expect(_runningTickers(tester), 1);

      await _teardown(tester);
    });

    testWidgets('a party that ends while its pin is on screen gives it back', (tester) async {
      // The half that a `late final` controller could never do. A pin outlives
      // its party — the map holds its pins until the next fetch — so the
      // ticker has to be disposed on the way down as well as created on the
      // way up.
      final pin = _pin(id: 'p', title: 'Τέλος', startsAt: start, endsAt: end, goingCount: 40);

      await _pumpPin(tester, pin, end.subtract(const Duration(minutes: 1)));
      expect(_runningTickers(tester), 1);

      await _pumpPin(tester, pin, end.add(const Duration(minutes: 1)));
      expect(_runningTickers(tester), 0);

      await _teardown(tester);
    });

    testWidgets('and can pick one up again after giving it back', (tester) async {
      // Recreating a controller on the same State is why this uses
      // TickerProviderStateMixin: the single-ticker mixin asserts on the
      // second createTicker, and a pin crossing a boundary twice is ordinary.
      final pin = _pin(id: 'p', title: 'Ξανά', startsAt: start, endsAt: end, goingCount: 40);

      await _pumpPin(tester, pin, start.add(const Duration(hours: 1)));
      await _pumpPin(tester, pin, end.add(const Duration(hours: 1)));
      await _pumpPin(tester, pin, start.add(const Duration(hours: 2)));

      expect(_runningTickers(tester), 1);
      await _teardown(tester);
    });
  });

  group('MpMapPin label', () {
    final start = DateTime.parse('2026-08-21T20:00:00Z');

    testWidgets('the pin draws the count and nothing else', (tester) async {
      // The whole label, asserted as an absence as much as a presence: the
      // title, the area and the unit suffix are the three things that were on
      // the pin and are now only in MapPinSheet, one tap away.
      final pin = _pin(
        id: 'p',
        title: 'Ταράτσα στο Κουκάκι',
        startsAt: start,
        interestedCount: 24,
      );

      await _pumpPin(tester, pin, start.subtract(const Duration(hours: 1)));

      expect(find.text('24'), findsOneWidget);
      expect(find.text('Ταράτσα στο Κουκάκι'), findsNothing);
      expect(find.text('24 interested'), findsNothing);
      expect(find.textContaining('interested'), findsNothing);

      await _teardown(tester);
    });

    testWidgets('a private pin draws a lock and never a number', (tester) async {
      // The last place attendance was still visible on a private pin. The
      // radius has been fixed since the map rework, but the LABEL printed the
      // count regardless, so the figure was on screen whatever the geometry
      // did. With the server no longer sending it there is nothing to print.
      final pin = _pin(
        id: 'p',
        title: 'Rooftop in Koukaki',
        startsAt: start,
        isPrivate: true,
        goingCount: null,
        interestedCount: null,
      );

      await _pumpPin(tester, pin, start.subtract(const Duration(hours: 1)));

      expect(find.byIcon(Icons.lock), findsOneWidget);
      // No digit anywhere in the marker.
      expect(
        find.byWidgetPredicate((w) => w is Text && RegExp(r'\d').hasMatch(w.data ?? '')),
        findsNothing,
      );

      await _teardown(tester);
    });

    testWidgets('a live pin draws the going count, still bare', (tester) async {
      final pin = _pin(
        id: 'p',
        title: 'Τώρα',
        startsAt: start,
        endsAt: start.add(const Duration(hours: 8)),
        goingCount: 12,
        interestedCount: 99,
      );

      await _pumpPin(tester, pin, start.add(const Duration(hours: 1)));

      expect(find.text('12'), findsOneWidget);
      expect(find.text('99'), findsNothing);
      expect(find.textContaining('here now'), findsNothing);

      await _teardown(tester);
    });

    testWidgets('every count from empty to four digits fits without overflowing', (tester) async {
      // Each of these would throw a RenderFlex overflow or clip visibly if the
      // step-down in labelSizeFor were dropped. 4237 is only reachable as a
      // live going_count, and only on a saturated bubble.
      for (final count in [0, 7, 25, 99, 100, 4237]) {
        final pin = _pin(id: 'p', title: 'Techno Noir', startsAt: start, goingCount: count);

        await _pumpPin(tester, pin, start.add(const Duration(hours: 1)));

        expect(find.text('$count'), findsOneWidget, reason: 'count $count');
        expect(tester.takeException(), isNull, reason: 'count $count overflowed its pin');

        // And it is inside the bubble, not merely rendered somewhere: the text
        // has to fit within the body circle it is centred in.
        final m = MpPinMetrics.forCount(count);
        final drawn = tester.getSize(find.text('$count'));
        expect(drawn.width, lessThanOrEqualTo(2 * m.drop.radius), reason: 'count $count');
      }

      await _teardown(tester);
    });

    testWidgets('a private pin is the same size whatever its count says', (tester) async {
      // The widget-level form of the geometry control: the number changes, the
      // silhouette does not. This is the property that keeps attendance
      // unreadable from a private pin's shape.
      final sizes = <Size>{};
      for (final count in [0, 1, 99, 5000]) {
        final pin = _pin(
          id: 'p',
          title: 'Ιδιωτικό',
          startsAt: start,
          interestedCount: count,
          isPrivate: true,
        );

        await _pumpPin(tester, pin, start.subtract(const Duration(hours: 1)));

        expect(find.text('$count'), findsOneWidget);
        sizes.add(tester.getSize(find.byType(MpMapPin)));
      }

      expect(sizes, hasLength(1));
      await _teardown(tester);
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
      // than passing by coincidence. Bare numbers now: the live one is the
      // going count, the upcoming one the interested count, and the pulse is
      // what distinguishes them.
      expect(find.text('12'), findsOneWidget);
      expect(find.text('34'), findsOneWidget);
      expect(find.text('99'), findsNothing);
      expect(find.text('88'), findsNothing);

      await _teardown(tester);
    });

    testWidgets('a screen of pins that are not live runs no tickers', (tester) async {
      // The screen-level form of the pulse-lifecycle tests: this is the number
      // that used to equal the pin count, whatever the pins were doing.
      final now = DateTime.now();
      final repository = _FakePartyRepository([
        for (var i = 0; i < 4; i++)
          _pin(
            id: 'upcoming_$i',
            title: 'Αύριο $i',
            startsAt: now.add(const Duration(days: 1)),
            interestedCount: 8 * i,
            latOffset: 0.0005 * i,
          ),
      ]);

      await _mount(tester, repository);

      expect(find.byType(MpMapPin), findsNWidgets(4));
      expect(_runningTickers(tester), 0);

      await _teardown(tester);
    });

    testWidgets('pin size tracks the count continuously instead of being uniform', (tester) async {
      final now = DateTime.now();
      final repository = _FakePartyRepository([
        _pin(id: 'small', title: 'Μικρό', startsAt: now.add(const Duration(days: 1)), interestedCount: 1),
        _pin(
          id: 'medium',
          title: 'Μεσαίο',
          startsAt: now.add(const Duration(days: 1)),
          interestedCount: 40,
          latOffset: 0.001,
        ),
        _pin(
          id: 'large',
          title: 'Μεγάλο',
          startsAt: now.add(const Duration(days: 1)),
          interestedCount: 400,
          latOffset: 0.002,
        ),
      ]);

      await _mount(tester, repository);

      // Found by the count now, not the title — the title is not on the pin
      // any more, which is the point of the change.
      Size sizeOf(int count) => tester.getSize(find.ancestor(
            of: find.text('$count'),
            matching: find.byType(MpMapPin),
          ));

      final small = sizeOf(1);
      final medium = sizeOf(40);
      final large = sizeOf(400);

      // BOTH axes move now. On the teardrop only the height varied, because
      // width was dominated by a chip that stepped in three fixed sizes; with
      // the chip gone width is 2r and carries the same signal the height does.
      expect(small.height, lessThan(medium.height));
      expect(medium.height, lessThan(large.height));
      expect(small.width, lessThan(medium.width));
      expect(medium.width, lessThan(large.width));

      // The top is SATURATED, not merely large. 400 interested and 100
      // interested draw the same bubble, which is what keeps 200 pins on one
      // screen readable.
      expect(
        large.height,
        closeTo(MpDropGeometry.maxRadius * (1 + MpDropGeometry.tipRatio), 0.01),
      );
      expect(large.width, closeTo(2 * MpDropGeometry.maxRadius, 0.01));

      // Asserted against the geometry rather than three literals, because the
      // failure that matters is the box disagreeing with what is painted
      // inside it — nothing clips the marker child, so a box narrower than its
      // contents does not error, it just overlaps the neighbouring pin.
      for (final (size, count) in [(small, 1), (medium, 40), (large, 400)]) {
        final m = MpPinMetrics.forCount(count);
        expect(size.width, closeTo(m.drop.width, 0.01));
        expect(size.height, closeTo(m.drop.height, 0.01));
      }

      await _teardown(tester);
    });

    testWidgets('the marker box is the size the pin actually draws at', (tester) async {
      // Two derivations of one number: the Marker declares its box and the
      // pill declares its extent. They used to come from two separate
      // DateTime.now() calls, so a party crossing its start time between them
      // would have been sized as upcoming in one and live in the other — and
      // a marker narrower than its pill clips it. Same instant now, passed
      // down.
      final now = DateTime.now();
      final repository = _FakePartyRepository([
        _pin(
          id: 'live',
          title: 'Τώρα',
          startsAt: now.subtract(const Duration(minutes: 1)),
          goingCount: 300,
          interestedCount: 2,
        ),
      ]);

      await _mount(tester, repository);

      // MarkerLayer wraps each child in a `Positioned(width:, height:)`, which
      // is a *tight* constraint — so this box is not merely around the pin,
      // it dictates the pin's size, and a box derived from the wrong tense
      // would squash the pill rather than sit loosely around it.
      final box = tester.widget<Positioned>(find
          .ancestor(of: find.byType(MpMapPin), matching: find.byType(Positioned))
          .first);
      final expected = MpPinMetrics.forCount(300);

      expect(box.width, expected.width);
      expect(box.height, expected.boxHeight);
      expect(tester.getSize(find.byType(MpMapPin)), Size(expected.width, expected.boxHeight));

      // And it is sized off the LIVE counter, not the interested one: 300
      // going, 2 interested. Had the screen read the wrong one the pin would
      // be squeezed into a minimum-radius box here, so the two sizes are
      // asserted apart rather than just asserted equal to each other.
      expect(expected.drop.radius, MpDropGeometry.maxRadius);
      expect(box.height, closeTo(expected.drop.height, 0.01));
      expect(MpPinMetrics.forCount(2).drop.radius, lessThan(MpDropGeometry.maxRadius * 0.6),
          reason: 'the interested count would have drawn a far smaller bubble');

      // THE ANCHOR. Inverting flutter_map's placement, the point lands at
      // (0.5·w·(1−ax), 0.5·h·(1−ay)) inside the box — which must be the apex.
      // Constant now that the box is symmetric, but still derived: a shape
      // whose apex left the bottom centre would fail here rather than quietly
      // move every party on the map.
      final marker = tester.widget<MpMapPin>(find.byType(MpMapPin));
      final anchored = Offset(
        0.5 * box.width! * (1 - expected.anchor.x),
        0.5 * box.height! * (1 - expected.anchor.y),
      );
      expect(anchored.dx, closeTo(expected.tip.dx, 0.01));
      expect(anchored.dy, closeTo(expected.tip.dy, 0.01));
      expect(marker.pin.id, 'live');

      expect(tester.takeException(), isNull);

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

    testWidgets('the search bar is wired, and does not carry the viewport with it', (tester) async {
      // It was a dead Container until Phase 14B. The assertion that matters is
      // not that a screen opens but that search is NOT scoped to the map: the
      // whole point is finding a party wherever it is, so no centre or radius
      // travels across this boundary.
      final repository = _FakePartyRepository(const []);

      await _mount(tester, repository);
      await tester.tap(find.text('Search parties or people'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SearchScreen), findsOneWidget);
      expect(find.text('Keep typing'), findsOneWidget,
          reason: 'it opens on the type-more state, having queried nothing');

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
      expect(find.text('Search parties or people'), findsOneWidget);

      await _teardown(tester);
    });
  });

  group('the time chips', () {
    testWidgets('all four render, and All is the default', (tester) async {
      final repository = _FakePartyRepository(const []);

      await _mount(tester, repository);

      expect(find.text('All'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
      expect(find.text('Later tonight'), findsOneWidget);
      expect(find.text('Weekend'), findsOneWidget);

      // The default matters more than it looks. Before this phase the enum
      // defaulted to `live` and nothing read it, so the pill row opened with
      // "Τώρα" highlighted over an unfiltered map -- a lie that was harmless
      // only because the filter did not work. Now that it does, a default of
      // anything but Όλα would hide most of the map on open.
      expect(repository.windows, [MapTimeWindow.all]);

      await _teardown(tester);
    });

    testWidgets('tapping a chip issues a NEW request with that window',
        (tester) async {
      final repository = _FakePartyRepository(const []);

      await _mount(tester, repository);
      expect(repository.calls, hasLength(1));

      await tester.tap(find.text('Live'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // A SECOND call, not a second look at the first one's rows. This is the
      // assertion the whole phase exists for: filtering `_pins` client-side
      // would leave this at one call and still look right on a map with no
      // pins on it.
      expect(repository.calls, hasLength(2));
      expect(repository.windows, [MapTimeWindow.all, MapTimeWindow.now]);

      await _teardown(tester);
    });

    testWidgets('each chip sends its own wire value', (tester) async {
      final repository = _FakePartyRepository(const []);

      await _mount(tester, repository);

      for (final label in const ['Later tonight', 'Weekend', 'All']) {
        await tester.tap(find.text(label));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(repository.windows, [
        MapTimeWindow.all,
        MapTimeWindow.tonight,
        MapTimeWindow.weekend,
        MapTimeWindow.all,
      ]);

      await _teardown(tester);
    });

    testWidgets('re-tapping the active chip does not refetch', (tester) async {
      final repository = _FakePartyRepository(const []);

      await _mount(tester, repository);

      await tester.tap(find.text('Live'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(repository.calls, hasLength(2));

      await tester.tap(find.text('Live'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Not merely an optimisation: the map query is the most expensive one in
      // the schema, and a pill row where every tap is a round trip makes an
      // idle thumb a load generator.
      expect(repository.calls, hasLength(2));
      expect(repository.windows.last, MapTimeWindow.now);

      await _teardown(tester);
    });
  });

  group('MapPinSheet', () {
    final start = DateTime.parse('2026-08-21T20:00:00Z');

    MapPartyPin full({
      String? description = 'Ταράτσα με θέα, φέρτε ποτό.',
      String? area = 'Κουκάκι',
      String? hostUsername = 'nikos',
      String? myRsvpStatus,
      String? coverPath,
      DateTime? startsAt,
      DateTime? endsAt,
      int? goingCount = 12,
      int? interestedCount = 34,
      bool isPrivate = false,
    }) {
      return MapPartyPin(
        id: 'aaaaaaaa-0000-0000-0000-000000000002',
        lat: _athens.lat,
        lng: _athens.lon,
        title: 'Syntagma Afterparty',
        isPrivate: isPrivate,
        goingCount: goingCount,
        interestedCount: interestedCount,
        startsAt: startsAt ?? start,
        endsAt: endsAt ?? start.add(const Duration(hours: 8)),
        area: area,
        description: description,
        hostId: '11111111-1111-1111-1111-111111111111',
        hostUsername: hostUsername,
        myRsvpStatus: myRsvpStatus,
        coverPath: coverPath,
      );
    }

    Future<void> pumpSheet(
      WidgetTester tester,
      MapPartyPin pin,
      _FakePartyRepository repository,
    ) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MapPinSheet(pin: pin, repository: repository)),
      ));
      await tester.pump();
    }

    /// The answer buttons sit below the fold of the 800x600 test viewport, so
    /// a bare tap() lands outside the render tree and hits nothing.
    Future<void> tapAnswer(WidgetTester tester, String label) async {
      await tester.ensureVisible(find.text(label));
      await tester.pump();
      await tester.tap(find.text(label));
      await tester.pump();
    }

    testWidgets('renders everything the pin stopped showing', (tester) async {
      // The whole point of stripping the pin: none of this is lost, it moves
      // one tap away. Asserted as a set rather than one field at a time
      // because the failure that matters is a section quietly missing, not a
      // section formatted differently.
      final repository = _FakePartyRepository(const []);
      await pumpSheet(tester, full(), repository);

      expect(find.text('Syntagma Afterparty'), findsOneWidget);
      expect(find.text('Ταράτσα με θέα, φέρτε ποτό.'), findsOneWidget);
      expect(find.text('Κουκάκι'), findsOneWidget);
      expect(find.text('@nikos'), findsOneWidget);
      expect(find.byTooltip('Report'), findsOneWidget);
    });

    testWidgets('shows BOTH counters, with the tense deciding which leads', (tester) async {
      // The pin has room for one number; the sheet is where both can be true
      // at once. A live party leads with who is inside and still reports
      // interest — and must not print the interested figure as if it were
      // attendance.
      final repository = _FakePartyRepository(const []);
      await pumpSheet(
        tester,
        full(
          startsAt: DateTime.now().subtract(const Duration(hours: 1)),
          endsAt: DateTime.now().add(const Duration(hours: 3)),
        ),
        repository,
      );

      expect(find.text('12 here now'), findsOneWidget);
      expect(find.text('34 interested'), findsOneWidget);
    });

    testWidgets('an upcoming party leads with interest instead', (tester) async {
      final repository = _FakePartyRepository(const []);
      await pumpSheet(
        tester,
        full(
          startsAt: DateTime.now().add(const Duration(days: 1)),
          endsAt: DateTime.now().add(const Duration(days: 1, hours: 4)),
        ),
        repository,
      );

      expect(find.text('34 interested'), findsOneWidget);
      expect(find.text('12 going'), findsOneWidget);
      expect(find.text('12 here now'), findsNothing);
    });

    testWidgets('a missing column is omitted, never rendered as a blank row', (tester) async {
      // area, description and host_username are all nullable, and an empty row
      // reads as a field that failed to load rather than one nobody filled in.
      final repository = _FakePartyRepository(const []);
      await pumpSheet(
        tester,
        full(description: null, area: null, hostUsername: null),
        repository,
      );

      expect(find.text('Syntagma Afterparty'), findsOneWidget);
      expect(find.byIcon(Icons.place_outlined), findsNothing);
      expect(find.byIcon(Icons.person_outline), findsNothing);
      // The time is the one fact that is non-null in the schema, so it stays.
      expect(find.byIcon(Icons.schedule), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a whitespace-only description is treated as absent', (tester) async {
      // `description` is host-written free text; the schema does not stop it
      // being blank, and a section containing only spaces is a gap with no
      // explanation.
      final repository = _FakePartyRepository(const []);
      await pumpSheet(tester, full(description: '   '), repository);

      expect(find.text('   '), findsNothing);
    });

    testWidgets('a public party offers both answers and lights the current one', (tester) async {
      // Two buttons, always both present -- switching between them is an
      // `update rsvps set status`, so the other answer has to stay reachable.
      // The tick is what moves.
      final repository = _FakePartyRepository(const []);

      await pumpSheet(tester, full(myRsvpStatus: null), repository);
      expect(find.text('Going'), findsOneWidget);
      expect(find.text('Interested'), findsOneWidget);

      await pumpSheet(tester, full(myRsvpStatus: 'interested'), repository);
      expect(find.text('Interested ✓'), findsOneWidget);
      expect(find.text('Going'), findsOneWidget);

      await pumpSheet(tester, full(myRsvpStatus: 'going'), repository);
      expect(find.text('Going ✓'), findsOneWidget);
      expect(find.text('Interested'), findsOneWidget);
    });

    testWidgets('a private party offers ONE answer, and it is not Interested', (tester) async {
      // The server refuses an 'interested' row on a private party
      // (20260825090050), so offering the button would be an affordance that
      // returns 42501. Asserted as an absence, which is the whole point.
      final repository = _FakePartyRepository(const []);

      await pumpSheet(tester, full(isPrivate: true, myRsvpStatus: null), repository);
      expect(find.text('Coming'), findsOneWidget);
      expect(find.text('Interested'), findsNothing);
      expect(find.text('Going'), findsNothing);

      await pumpSheet(tester, full(isPrivate: true, myRsvpStatus: 'going'), repository);
      expect(find.text('You are coming ✓'), findsOneWidget);
      expect(find.text('Interested'), findsNothing);
    });

    testWidgets('Interested writes the rsvp, ticks, and counts the viewer in', (tester) async {
      // Not live (the fixture party ended in August), so the lead number is
      // interested_count -- the one the map pin draws -- and it must move on
      // the tap, not after a round trip.
      final repository = _FakePartyRepository(const []);
      final published = <RsvpChange?>[];
      void listener() => published.add(rsvpChanges.value);
      rsvpChanges.addListener(listener);
      addTearDown(() => rsvpChanges.removeListener(listener));

      await pumpSheet(tester, full(), repository);
      expect(find.text('34 interested'), findsOneWidget);

      await tapAnswer(tester, 'Interested');

      expect(repository.rsvpWrites.single.status, MpRsvp.interested);
      expect(repository.rsvpWrites.single.current, isNull);
      expect(find.text('Interested ✓'), findsOneWidget);
      expect(find.text('35 interested'), findsOneWidget);
      expect(find.text('12 going'), findsOneWidget);
      // Published only once the write landed, which is what tells the map and
      // MY PARTIES to refetch.
      expect(published.single!.partyId, 'aaaaaaaa-0000-0000-0000-000000000002');
      expect(published.single!.status, MpRsvp.interested);
    });

    testWidgets('switching interested -> going moves going ONLY', (tester) async {
      // interested_count includes everyone going, so a flip changes nobody's
      // interested membership -- the trigger's UPDATE branch touches one
      // column, and the optimistic number must agree with it.
      final repository = _FakePartyRepository(const []);
      await pumpSheet(tester, full(myRsvpStatus: 'interested'), repository);

      await tapAnswer(tester, 'Going');

      expect(repository.rsvpWrites.single.current, MpRsvp.interested);
      expect(find.text('Going ✓'), findsOneWidget);
      expect(find.text('34 interested'), findsOneWidget);
      expect(find.text('13 going'), findsOneWidget);
    });

    testWidgets('tapping the lit answer withdraws it and counts the viewer out', (tester) async {
      final repository = _FakePartyRepository(const []);
      await pumpSheet(tester, full(myRsvpStatus: 'going'), repository);

      await tapAnswer(tester, 'Going ✓');

      expect(repository.rsvpWrites.single.status, MpRsvp.going);
      expect(repository.rsvpWrites.single.current, MpRsvp.going);
      expect(find.text('Going'), findsOneWidget);
      expect(find.text('33 interested'), findsOneWidget);
      expect(find.text('11 going'), findsOneWidget);
    });

    testWidgets('a failed write rolls the sheet back and publishes nothing', (tester) async {
      final repository = _FakePartyRepository(const [])..rsvpFails = true;
      var notified = 0;
      void listener() => notified++;
      rsvpChanges.addListener(listener);
      addTearDown(() => rsvpChanges.removeListener(listener));

      await pumpSheet(tester, full(), repository);
      await tapAnswer(tester, 'Going');
      await tester.pump();

      expect(find.text('Going'), findsOneWidget);
      expect(find.text('34 interested'), findsOneWidget);
      expect(find.text('That did not save.'), findsOneWidget);
      expect(notified, 0);
    });

    testWidgets('a private party shows no counts in the sheet at all', (tester) async {
      // goingCount/interestedCount are null because the RPC no longer sends
      // them for a private row. The counts row is omitted rather than blanked
      // or zeroed -- "0 going" is a legible, wrong answer.
      final repository = _FakePartyRepository(const []);
      await pumpSheet(
        tester,
        full(isPrivate: true, goingCount: null, interestedCount: null),
        repository,
      );

      expect(find.textContaining('interested'), findsNothing);
      expect(find.textContaining('going'), findsNothing);
      expect(find.textContaining('here now'), findsNothing);
      expect(find.text('0'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a party with no cover never asks storage to sign one', (tester) async {
      // `party-covers` is private and every signature is a round trip, so the
      // sheet must not spend one to be told there is no object.
      final repository = _FakePartyRepository(const []);
      await pumpSheet(tester, full(coverPath: null), repository);

      expect(repository.signRequests, isEmpty);
    });

    testWidgets('a party with a cover signs exactly its own path', (tester) async {
      final repository = _FakePartyRepository(const [])
        ..signedCover = 'https://example.test/signed.jpg';

      await pumpSheet(
        tester,
        full(coverPath: 'aaaaaaaa-0000-0000-0000-000000000002/cover.jpg'),
        repository,
      );
      await tester.pump();

      expect(repository.signRequests,
          ['aaaaaaaa-0000-0000-0000-000000000002/cover.jpg']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a cover that will not sign falls back to the placeholder', (tester) async {
      // Same rendering as a party that never had one: there is deliberately no
      // error state for a picture.
      final repository = _FakePartyRepository(const [])..signedCover = null;

      await pumpSheet(
        tester,
        full(coverPath: 'aaaaaaaa-0000-0000-0000-000000000002/cover.jpg'),
        repository,
      );
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a pin opens THIS sheet, not a lookalike', (tester) async {
      // The map half of the shared-sheet rule; search_test.dart asserts the
      // other half. Both must reach MapPinSheet itself, because that is what
      // makes the report action and the counts identical from either screen.
      final now = DateTime.now();
      final repository = _FakePartyRepository([
        _pin(
          id: 'p',
          title: 'Ταράτσα',
          startsAt: now.add(const Duration(days: 1)),
          endsAt: now.add(const Duration(days: 1, hours: 4)),
          interestedCount: 7,
        ),
      ]);

      await _mount(tester, repository);
      await tester.tap(find.byType(MpMapPin));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(MapPinSheet), findsOneWidget);
      expect(find.text('Ταράτσα'), findsOneWidget);

      await _teardown(tester);
    });
  });
}
