import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:myparty/services/geocoding_service.dart';

/// Trimmed from real MapTiler answers (2026-10-20): "Αισχύλου 12" near central
/// Athens, and a reverse lookup in Psyri.
final _forward = File('test/fixtures/maptiler_forward.json').readAsStringSync();
final _reverse = File('test/fixtures/maptiler_reverse.json').readAsStringSync();

http.Response _json(String body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

const _athens = LatLng(37.9838, 23.7275);

void main() {
  group('parsing', () {
    test('a forward answer becomes places: label without the country, the centre as the point', () {
      final places = GeocodingService.parseFeatureCollection(jsonDecode(_forward));

      expect(places, hasLength(2), reason: 'the feature with no centre is skipped, not fatal');
      expect(places.first.label, 'Αισχύλου 12, 105 54 Αθήνα');
      expect(places.first.point.latitude, closeTo(37.978742, 1e-9));
      expect(places.first.point.longitude, closeTo(23.72517, 1e-6));
      expect(places[1].label, 'Αισχύλου 12, 163 43 Ηλιούπολη');
    });

    test('the area is the neighbourhood, else the municipality, never the admin "locality"', () {
      final places = GeocodingService.parseFeatureCollection(jsonDecode(_forward));

      expect(places.first.area, 'Ψυρρή');
      expect(places[1].area, 'Ηλιούπολη', reason: 'no place.* in its context');
    });

    test('a result that IS a neighbourhood is its own area', () {
      final places = GeocodingService.parseFeatureCollection(jsonDecode(_reverse));
      expect(places[1].label, 'Ψυρρή, Αθήνα');
      expect(places[1].area, 'Ψυρρή');
    });

    test('labels and areas are capped to their columns and kept to one line', () {
      final place = GeocodingService.parseFeature({
        'center': [23.7, 37.9],
        'place_name': '${'α' * 250}\nsecond line',
        'context': [
          {'id': 'place.1', 'text': 'β' * 120},
        ],
      })!;
      expect(place.label.length, lessThanOrEqualTo(maxAddressLength));
      expect(place.label, isNot(contains('\n')));
      expect(place.area!.length, lessThanOrEqualTo(maxAreaLength));
    });

    test('a centre that is not a coordinate is skipped', () {
      expect(GeocodingService.parseFeature({'center': [200, 37], 'place_name': 'x'}), isNull);
      expect(GeocodingService.parseFeature({'center': ['a', 'b'], 'place_name': 'x'}), isNull);
      expect(GeocodingService.parseFeature({'place_name': 'x'}), isNull);
      expect(GeocodingService.parseFeature('nope'), isNull);
    });

    test('something that is not a FeatureCollection is a format error', () {
      expect(() => GeocodingService.parseFeatureCollection({'hello': 1}), throwsFormatException);
    });
  });

  group('requests', () {
    test('search sends the query, the bias, autocomplete, Greek-then-English and the key', () async {
      late Uri seen;
      final service = GeocodingService(
        apiKey: 'k3y',
        client: MockClient((request) async {
          seen = request.url;
          return _json(_forward);
        }),
      );

      final result = await service.search('  Αισχύλου 12 ', near: _athens);

      expect(result, isA<GeocodeFound>());
      expect((result as GeocodeFound).places, hasLength(2));
      expect(seen.host, 'api.maptiler.com');
      expect(Uri.decodeComponent(seen.path), '/geocoding/Αισχύλου 12.json');
      expect(seen.queryParameters['proximity'], '23.7275,37.9838');
      expect(seen.queryParameters['autocomplete'], 'true');
      expect(seen.queryParameters['language'], 'el,en');
      expect(seen.queryParameters['key'], 'k3y');
      expect(seen.queryParameters.containsKey('country'), isFalse,
          reason: 'biased, not restricted: a party abroad is still findable');
    });

    test('English input goes out as typed', () async {
      late Uri seen;
      final service = GeocodingService(
        apiKey: 'k',
        client: MockClient((request) async {
          seen = request.url;
          return _json('{"type":"FeatureCollection","features":[]}');
        }),
      );
      await service.search('Ermou 10 Athens', near: _athens);
      expect(Uri.decodeComponent(seen.path), '/geocoding/Ermou 10 Athens.json');
      expect(seen.path, isNot(contains('%25')), reason: 'encoded once, not twice');
    });

    test('a slash in the query stays inside one path segment', () async {
      late Uri seen;
      final service = GeocodingService(
        apiKey: 'k',
        client: MockClient((request) async {
          seen = request.url;
          return _json('{"type":"FeatureCollection","features":[]}');
        }),
      );
      await service.search('Ερμού 3/5', near: _athens);
      expect(seen.pathSegments, ['geocoding', 'Ερμού 3/5.json']);
    });

    test('reverse asks for lon,lat and keeps only the most specific answer', () async {
      late Uri seen;
      final service = GeocodingService(
        apiKey: 'k',
        client: MockClient((request) async {
          seen = request.url;
          return _json(_reverse);
        }),
      );

      final result = await service.reverse(const LatLng(37.9781, 23.7234));

      expect(seen.path, '/geocoding/23.7234,37.9781.json');
      expect(seen.queryParameters['limit'], '1');
      final places = (result as GeocodeFound).places;
      expect(places, hasLength(1));
      expect(places.single.label, 'Χριστοκοπίδου 14, 105 55 Αθήνα');
      expect(places.single.area, 'Ψυρρή');
    });

    test('no matches is an empty answer, not a failure', () async {
      final service = GeocodingService(
        apiKey: 'k',
        client: MockClient((_) async => _json('{"type":"FeatureCollection","features":[]}')),
      );
      final result = await service.search('zzzzqqq', near: _athens);
      expect(result, isA<GeocodeFound>());
      expect((result as GeocodeFound).places, isEmpty);
    });
  });

  group('errors', () {
    Future<GeocodeResult> withResponse(FutureOr<http.Response> Function() respond) =>
        GeocodingService(apiKey: 'k', client: MockClient((_) async => respond()))
            .search('Ερμού', near: _athens);

    GeocodeFailure? failureOf(GeocodeResult r) => r is GeocodeFailed ? r.failure : null;

    test('no key: unavailable, and nothing is sent', () async {
      var calls = 0;
      final service = GeocodingService(
        apiKey: '',
        client: MockClient((_) async {
          calls++;
          return _json(_forward);
        }),
      );
      expect(failureOf(await service.search('Ερμού', near: _athens)), GeocodeFailure.unavailable);
      expect(failureOf(await service.reverse(_athens)), GeocodeFailure.unavailable);
      expect(calls, 0);
    });

    test('403 (bad or restricted key): unavailable', () async {
      expect(failureOf(await withResponse(() => http.Response('Invalid key', 403))), GeocodeFailure.unavailable);
    });

    test('429 (rate or quota): busy', () async {
      expect(failureOf(await withResponse(() => http.Response('Too Many Requests', 429))), GeocodeFailure.busy);
    });

    test('5xx: busy', () async {
      expect(failureOf(await withResponse(() => http.Response('oops', 503))), GeocodeFailure.busy);
    });

    test('400 (a query MapTiler will not take): no matches', () async {
      final result = await withResponse(() => http.Response('bad', 400));
      expect((result as GeocodeFound).places, isEmpty);
    });

    test('a 200 that is not JSON: busy', () async {
      expect(failureOf(await withResponse(() => http.Response('<html>', 200))), GeocodeFailure.busy);
    });

    test('no connection: network', () async {
      expect(failureOf(await withResponse(() => throw const SocketException('down'))), GeocodeFailure.network);
      expect(failureOf(await withResponse(() => throw http.ClientException('reset'))), GeocodeFailure.network);
    });

    test('no answer in time: network', () {
      fakeAsync((async) {
        GeocodeResult? result;
        GeocodingService(
          apiKey: 'k',
          timeout: const Duration(seconds: 8),
          client: MockClient((_) => Completer<http.Response>().future),
        ).search('Ερμού', near: _athens).then((r) => result = r);
        async.elapse(const Duration(seconds: 9));
        expect(failureOf(result!), GeocodeFailure.network);
      });
    });

    test('every failure message offers the manual pin', () {
      for (final f in GeocodeFailure.values) {
        expect(geocodeFailureMessage(f), contains('pin'));
      }
      expect(geocodeNoResultsMessage, contains('pin'));
    });
  });

  group('GeocodeSearchController', () {
    /// Records each query and answers it after [latency].
    ({GeocodeSearchController controller, List<String> queries}) make({
      Duration latency = Duration.zero,
      GeocodeResult Function(String q)? answer,
    }) {
      final queries = <String>[];
      final service = _ScriptedGeocoder((q) async {
        queries.add(q);
        await Future<void>.delayed(latency);
        return answer?.call(q) ??
            GeocodeFound([GeocodedPlace(label: 'hit for $q', point: _athens)]);
      });
      final controller = GeocodeSearchController(service: service, near: () async => _athens);
      return (controller: controller, queries: queries);
    }

    test('nothing under 3 characters', () {
      fakeAsync((async) {
        final s = make();
        s.controller.onQueryChanged('Ερ');
        async.elapse(const Duration(seconds: 1));
        expect(s.queries, isEmpty);
        expect(s.controller.value, isA<GeocodeSearchIdle>());
      });
    });

    test('keystrokes 400ms apart or less make ONE request, for the last text', () {
      fakeAsync((async) {
        final s = make();
        s.controller.onQueryChanged('Ερμ');
        async.elapse(const Duration(milliseconds: 200));
        s.controller.onQueryChanged('Ερμο');
        async.elapse(const Duration(milliseconds: 399));
        s.controller.onQueryChanged('Ερμού');
        async.elapse(const Duration(milliseconds: 399));
        expect(s.queries, isEmpty, reason: 'still inside the debounce window');

        async.elapse(const Duration(milliseconds: 2));
        async.flushMicrotasks();
        expect(s.queries, ['Ερμού']);
        final state = s.controller.value as GeocodeSearchResults;
        expect(state.places.single.label, 'hit for Ερμού');
      });
    });

    test('an answer for text that is no longer in the field is dropped', () {
      fakeAsync((async) {
        final s = make(latency: const Duration(seconds: 2));
        s.controller.onQueryChanged('Ερμού');
        async.elapse(const Duration(milliseconds: 401)); // first request in flight
        s.controller.onQueryChanged('Αισχύλου');
        async.elapse(const Duration(milliseconds: 1700)); // first answer lands now
        expect(s.controller.value, isNot(isA<GeocodeSearchResults>()),
            reason: 'the Ερμού answer must not show under Αισχύλου');

        async.elapse(const Duration(seconds: 3));
        expect(s.queries, ['Ερμού', 'Αισχύλου']);
        expect((s.controller.value as GeocodeSearchResults).places.single.label, 'hit for Αισχύλου');
      });
    });

    test('shortening the text below 3 cancels a pending search', () {
      fakeAsync((async) {
        final s = make();
        s.controller.onQueryChanged('Ερμού');
        async.elapse(const Duration(milliseconds: 100));
        s.controller.onQueryChanged('Ερ');
        async.elapse(const Duration(seconds: 1));
        expect(s.queries, isEmpty);
        expect(s.controller.value, isA<GeocodeSearchIdle>());
      });
    });

    test('clear() hides the list and drops an answer in flight', () {
      fakeAsync((async) {
        final s = make(latency: const Duration(seconds: 1));
        s.controller.onQueryChanged('Ερμού');
        async.elapse(const Duration(milliseconds: 500));
        s.controller.clear();
        async.elapse(const Duration(seconds: 2));
        expect(s.controller.value, isA<GeocodeSearchIdle>());
      });
    });

    test('a failure becomes an error state', () {
      fakeAsync((async) {
        final s = make(answer: (_) => const GeocodeFailed(GeocodeFailure.busy));
        s.controller.onQueryChanged('Ερμού');
        async.elapse(const Duration(milliseconds: 401));
        expect((s.controller.value as GeocodeSearchError).failure, GeocodeFailure.busy);
      });
    });
  });
}

class _ScriptedGeocoder extends GeocodingService {
  _ScriptedGeocoder(this._answer) : super(apiKey: 'k', client: MockClient((_) async => http.Response('', 500)));

  final Future<GeocodeResult> Function(String query) _answer;

  @override
  Future<GeocodeResult> search(String query, {required LatLng near, int limit = 5}) => _answer(query);
}
