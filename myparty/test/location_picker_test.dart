import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:myparty/ui/screens/location_picker_screen.dart';
import 'package:myparty/ui/widgets/map_base.dart';

/// Pushes the picker from a launcher button and records what it pops with,
/// so every test asserts on the value the host wizard would actually receive.
Future<List<LatLng?>> _open(
  WidgetTester tester, {
  LatLng? initial,
  LocationFix? locate,
}) async {
  final results = <LatLng?>[];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          results.add(await Navigator.of(context).push<LatLng>(MaterialPageRoute(
            builder: (_) => LocationPickerScreen(initial: initial, locate: locate),
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

  testWidgets('opens on a point picked earlier and hands it back untouched', (tester) async {
    var located = false;
    final results = await _open(tester, initial: syntagma, locate: () async {
      located = true;
      return kifisia;
    });

    expect(located, isFalse, reason: 'adjusting a choice must not jump to the device fix');
    expect(find.text('37.97550, 23.73480'), findsOneWidget);

    await _confirm(tester);
    expect(results.single!.latitude, closeTo(syntagma.latitude, 1e-9));
    expect(results.single!.longitude, closeTo(syntagma.longitude, 1e-9));
  });

  testWidgets('with nothing picked yet it opens on the device fix', (tester) async {
    final results = await _open(tester, locate: () async => kifisia);

    expect(find.text('38.07380, 23.81110'), findsOneWidget);
    await _confirm(tester);
    expect(results.single!.latitude, closeTo(kifisia.latitude, 1e-9));
  });

  testWidgets('with no fix at all it falls back to central Athens', (tester) async {
    final results = await _open(tester, locate: () async => null);

    await _confirm(tester);
    expect(results.single!.latitude, closeTo(kDefaultMapCentre.latitude, 1e-9));
    expect(results.single!.longitude, closeTo(kDefaultMapCentre.longitude, 1e-9));
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
    expect(picked.latitude, lessThan(syntagma.latitude), reason: 'dragged up => point moved south');
    expect(picked.longitude, greaterThan(syntagma.longitude), reason: 'dragged left => point moved east');
    expect(find.text(formatPickedPoint(picked)), findsNothing, reason: 'the picker has closed');
  });
}
