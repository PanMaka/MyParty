import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:myparty/services/geocoding_service.dart';
import 'package:myparty/ui/screens/location_picker_screen.dart';
import 'package:myparty/ui/widgets/map_base.dart';

import 'support/fake_geocoder.dart';

/// Pushes the picker from a launcher button and records what it pops with,
/// so every test asserts on the value the host wizard would actually receive.
Future<List<PickedSpot?>> _open(
  WidgetTester tester, {
  LatLng? initial,
  LocationFix? locate,
  GeocodingService? geocoder,
}) async {
  final results = <PickedSpot?>[];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          results.add(await Navigator.of(context).push<PickedSpot>(MaterialPageRoute(
            builder: (_) => LocationPickerScreen(
              initial: initial,
              locate: locate,
              geocoder: geocoder ?? FakeGeocoder(),
            ),
          )));
        },
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return results;
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('location-picker-confirm')));
  // Settled, not pumped a fixed time: after a drag the map is still flinging,
  // and the route's exit transition runs on top of that.
  await tester.pumpAndSettle();
}

void main() {
  const syntagma = LatLng(37.97550, 23.73480);
  const kifisia = LatLng(38.07380, 23.81110);
  const aischylou = GeocodedPlace(
    label: 'Αισχύλου 12, 105 54 Αθήνα',
    point: LatLng(37.97874, 23.72517),
    area: 'Ψυρρή',
  );

  testWidgets('opens on a point picked earlier and hands it back untouched', (tester) async {
    var located = false;
    final results = await _open(tester, initial: syntagma, locate: () async {
      located = true;
      return kifisia;
    });

    expect(located, isFalse, reason: 'adjusting a choice must not jump to the device fix');
    expect(find.text('37.97550, 23.73480'), findsOneWidget);

    await _confirm(tester);
    expect(results.single!.point.latitude, closeTo(syntagma.latitude, 1e-9));
    expect(results.single!.point.longitude, closeTo(syntagma.longitude, 1e-9));
    expect(results.single!.place, isNull);
  });

  testWidgets('with nothing picked yet it opens on the device fix', (tester) async {
    final results = await _open(tester, locate: () async => kifisia);

    expect(find.text('38.07380, 23.81110'), findsOneWidget);
    await _confirm(tester);
    expect(results.single!.point.latitude, closeTo(kifisia.latitude, 1e-9));
  });

  testWidgets('with no fix at all it opens on central Athens but will not use it until moved', (tester) async {
    final results = await _open(tester, locate: () async => null);

    expect(find.text(formatPickedPoint(kDefaultMapCentre)), findsOneWidget);
    expect(find.textContaining('Search for the address, or move the map'), findsOneWidget);

    await tester.tap(find.byKey(const Key('location-picker-confirm')));
    await tester.pumpAndSettle();
    expect(results, isEmpty, reason: 'no silent default: the fallback centre is not a location');
    expect(find.byType(LocationPickerScreen), findsOneWidget);

    await tester.drag(find.byType(FlutterMap), const Offset(-60, -60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _confirm(tester);

    expect(results, hasLength(1));
    expect(results.single!.point, isNot(kDefaultMapCentre));
  });

  testWidgets('backing out returns nothing, so the wizard keeps what it had', (tester) async {
    final results = await _open(tester, initial: syntagma);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(results, [null]);
  });

  testWidgets('dragging the map moves the point under the pin, and that is what is returned', (tester) async {
    final results = await _open(tester, initial: syntagma);

    // Drag the map up and to the left: the content moves with the finger, so
    // the point under the fixed centre pin moves south-east.
    await tester.drag(find.byType(FlutterMap), const Offset(-120, -160));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('37.97550, 23.73480'), findsNothing,
        reason: 'the coordinates on screen follow the map');

    await _confirm(tester);
    final picked = results.single!;
    expect(picked.point.latitude, lessThan(syntagma.latitude), reason: 'dragged up => point moved south');
    expect(picked.point.longitude, greaterThan(syntagma.longitude), reason: 'dragged left => point moved east');
    expect(picked.place, isNull, reason: 'a dragged pin has no search result attached');
  });

  group('search', () {
    testWidgets('choosing a suggestion moves the map there, and it comes back with the pin', (tester) async {
      final geocoder = FakeGeocoder(places: [aischylou]);
      final results = await _open(tester, locate: () async => null, geocoder: geocoder);

      await tester.enterText(find.byKey(const Key('location-picker-search')), 'Αισχύλου 12');
      await tester.pump(const Duration(milliseconds: 401));
      await tester.pump();
      expect(geocoder.searches, ['Αισχύλου 12']);
      expect(find.text('Αισχύλου 12'), findsWidgets);

      await tester.tap(find.byKey(const Key('address-suggestion-0')));
      await tester.pumpAndSettle();
      expect(find.text(formatPickedPoint(aischylou.point)), findsOneWidget);

      await _confirm(tester);
      final picked = results.single!;
      expect(picked.point.latitude, closeTo(aischylou.point.latitude, 1e-6));
      expect(picked.point.longitude, closeTo(aischylou.point.longitude, 1e-6));
      expect(picked.place, aischylou, reason: 'unmoved since, so the label rides along');
    });

    testWidgets('a suggestion then a drag: the drag wins and the label is dropped', (tester) async {
      final results = await _open(tester, initial: syntagma, geocoder: FakeGeocoder(places: [aischylou]));

      await tester.enterText(find.byKey(const Key('location-picker-search')), 'Αισχύλου');
      await tester.pump(const Duration(milliseconds: 401));
      await tester.pump();
      await tester.tap(find.byKey(const Key('address-suggestion-0')));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(FlutterMap), const Offset(80, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _confirm(tester);

      expect(results.single!.place, isNull);
      expect(results.single!.point.longitude, lessThan(aischylou.point.longitude));
    });

    testWidgets('a failed search says so and leaves the map usable', (tester) async {
      final results = await _open(
        tester,
        initial: syntagma,
        geocoder: FakeGeocoder(searchFailure: GeocodeFailure.unavailable),
      );

      await tester.enterText(find.byKey(const Key('location-picker-search')), 'Ερμού 10');
      await tester.pump(const Duration(milliseconds: 401));
      await tester.pump();
      expect(find.text(geocodeFailureMessage(GeocodeFailure.unavailable)), findsOneWidget);

      await _confirm(tester);
      expect(results.single!.point, syntagma);
    });

    testWidgets('the attribution is always on screen', (tester) async {
      await _open(tester, initial: syntagma);
      expect(find.text(geocodeAttribution), findsOneWidget);
    });
  });
}
