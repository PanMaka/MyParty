import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myparty/utils/directions.dart';

void main() {
  group('directionsUri', () {
    test('coordinates become "lat,lng" on the universal directions URL', () {
      final uri = directionsUri(lat: 37.9755, lng: 23.7348, address: 'Σύνταγμα')!;

      expect(uri.scheme, 'https');
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/maps/dir/');
      expect(uri.queryParameters['api'], '1');
      // Coordinates win over the address, and lat comes first — Maps reads
      // "23.7348,37.9755" as a point in Somalia.
      expect(uri.queryParameters['destination'], '37.9755,23.7348');
    });

    test('there is no origin, so Maps starts from the viewer\'s own position', () {
      final uri = directionsUri(lat: 37.9755, lng: 23.7348)!;
      expect(uri.queryParameters.containsKey('origin'), isFalse);
    });

    test('without coordinates a Greek address is percent-encoded as UTF-8', () {
      const address = 'Ζησιμοπούλου 8, Νέα Σμύρνη';
      final uri = directionsUri(address: address)!;

      // Round-trips exactly...
      expect(uri.queryParameters['destination'], address);
      // ...and the wire form is pure ASCII: no raw Greek, no raw space, no
      // raw comma that could be mistaken for a lat,lng separator.
      final query = uri.toString().split('?').last;
      expect(query, matches(RegExp(r'^[\x21-\x7E]+$')));
      expect(query, contains('%CE%96')); // Ζ
      expect(query, isNot(contains(',')));
    });

    test('an address is trimmed', () {
      expect(directionsUri(address: '  Ψυρρή  ')!.queryParameters['destination'], 'Ψυρρή');
    });

    test('invalid coordinates fall back to the address', () {
      expect(directionsUri(lat: 95, lng: 23.7, address: 'Κουκάκι')!.queryParameters['destination'], 'Κουκάκι');
      expect(directionsUri(lat: double.nan, lng: 23.7, address: 'Κουκάκι')!.queryParameters['destination'], 'Κουκάκι');
      expect(directionsUri(lat: 37.9, address: 'Κουκάκι')!.queryParameters['destination'], 'Κουκάκι');
    });

    test('no coordinates and no address is null, not a URL to nowhere', () {
      expect(directionsUri(), isNull);
      expect(directionsUri(address: ''), isNull);
      expect(directionsUri(address: '   '), isNull);
      expect(directionsUri(lat: 37.9), isNull);
    });
  });

  group('openDirections', () {
    Future<BuildContext> pumpHost(WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        })),
      ));
      return ctx;
    }

    testWidgets('hands the URL to the launcher and says nothing on success', (tester) async {
      final ctx = await pumpHost(tester);
      Uri? launched;
      await openDirections(ctx, lat: 37.9755, lng: 23.7348, launch: (uri) async {
        launched = uri;
        return true;
      });
      await tester.pump();

      expect(launched, directionsUri(lat: 37.9755, lng: 23.7348));
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a launch that returns false shows a snackbar', (tester) async {
      final ctx = await pumpHost(tester);
      await openDirections(ctx, lat: 37.9755, lng: 23.7348, launch: (_) async => false);
      await tester.pump();

      expect(find.text("Couldn't open Google Maps"), findsOneWidget);
    });

    testWidgets('a launch that throws shows the same snackbar', (tester) async {
      final ctx = await pumpHost(tester);
      await openDirections(ctx, lat: 37.9755, lng: 23.7348, launch: (_) async => throw Exception('no activity'));
      await tester.pump();

      expect(find.text("Couldn't open Google Maps"), findsOneWidget);
    });

    testWidgets('no location never reaches the launcher', (tester) async {
      final ctx = await pumpHost(tester);
      var called = false;
      await openDirections(ctx, launch: (_) async => called = true);
      await tester.pump();

      expect(called, isFalse);
      expect(find.text('No location for this party'), findsOneWidget);
    });
  });
}
