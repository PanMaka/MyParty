import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myparty/ui/widgets/basemap.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

/// Records what the renderer says it could not read.
class _Warnings implements vtr.Logger {
  final messages = <String>[];

  @override
  void log(vtr.MessageFunction message) {}

  @override
  void warn(vtr.MessageFunction message) => messages.add(message());
}

const _tileJsonUrl = 'https://tiles.openfreemap.org/planet';
const _tiles = 'https://tiles.openfreemap.org/planet/20261018_080001_pt/{z}/{x}/{y}.pbf';
final _tileJson = jsonEncode({
  'tilejson': '3.0.0',
  'tiles': [_tiles],
  'minzoom': 0,
  'maxzoom': 14,
});

/// The source layers OpenFreeMap's TileJSON lists (read 2026-10-22). A layer
/// naming anything else draws nothing, silently.
const _openMapTilesLayers = {
  'aerodrome_label', 'aeroway', 'boundary', 'building', 'housenumber', 'landcover', 'landuse', //
  'mountain_peak', 'park', 'place', 'poi', 'transportation', 'transportation_name', 'water', //
  'water_name', 'waterway',
};

Future<Map<String, dynamic>> _style() async =>
    jsonDecode(await rootBundle.loadString(kBasemapStyle)) as Map<String, dynamic>;

/// Every `#rrggbb` the style paints with.
Iterable<String> _colours(Object? node) sync* {
  if (node is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(node)) yield node;
  if (node is Map) {
    for (final v in node.values) {
      yield* _colours(v);
    }
  }
  if (node is List) {
    for (final v in node) {
      yield* _colours(v);
    }
  }
}

Color _hex(String s) => Color(int.parse('ff${s.substring(1)}', radix: 16));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the bundled style', () {
    test('every layer is one the renderer can draw, with nothing it skips', () async {
      final json = await _style();
      final warnings = _Warnings();
      final theme = vtr.ThemeReader(logger: warnings).read(json);
      expect(warnings.messages, isEmpty);
      // A layer type the renderer does not know is dropped with only a warning;
      // the count catches one that is dropped without even that.
      expect(theme.layers, hasLength((json['layers'] as List).length));
    });

    test('its background is the colour the maps paint before it loads', () async {
      final layers = (await _style())['layers'] as List;
      final background = layers.firstWhere((l) => l['type'] == 'background');
      expect(_hex(background['paint']['background-color'] as String), kBasemapBackground);
    });

    test('it reads only layers OpenFreeMap serves, from the one TileJSON source', () async {
      final json = await _style();
      expect(json['sources'], {
        'openmaptiles': {'type': 'vector', 'url': _tileJsonUrl},
      });
      for (final layer in (json['layers'] as List).where((l) => l['type'] != 'background')) {
        expect(layer['source'], 'openmaptiles', reason: layer['id'] as String);
        expect(_openMapTilesLayers, contains(layer['source-layer']), reason: layer['id'] as String);
      }
    });

    test('nothing in it is purple or pink: those belong to the pins', () async {
      for (final colour in _colours((await _style())['layers'])) {
        final hsl = HSLColor.fromColor(_hex(colour));
        final purpleOrPink = hsl.hue >= 255 && hsl.hue <= 345 && hsl.saturation > 0.12;
        expect(purpleOrPink, isFalse, reason: '$colour is hue ${hsl.hue.round()}');
      }
    });

    test('no points of interest, house numbers or icons compete with the pins', () async {
      final json = await _style();
      final layers = json['layers'] as List;
      expect(layers.map((l) => l['source-layer']), isNot(contains('poi')));
      expect(layers.map((l) => l['source-layer']), isNot(contains('housenumber')));
      expect(layers.where((l) => (l['layout'] as Map?)?.containsKey('icon-image') ?? false), isEmpty);
      expect(json.containsKey('sprite'), isFalse);
    });
  });

  group('Basemap', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('loads the bundled style once, with the tiles its TileJSON names', () async {
      var requests = 0;
      final basemap = Basemap(client: MockClient((request) async {
        requests++;
        expect(request.url.toString(), _tileJsonUrl);
        return http.Response(_tileJson, 200);
      }));

      expect(await basemap.ensureLoaded(), isTrue);
      expect(await basemap.ensureLoaded(), isTrue);
      expect(requests, 1);

      final style = basemap.style.value!;
      expect(style.theme.id, 'myparty-dark');
      expect(style.theme.version, Basemap.fingerprint(await rootBundle.loadString(kBasemapStyle)));
      final provider = style.providers.get('openmaptiles') as NetworkVectorTileProvider;
      expect(provider.maximumZoom, 14);
      expect(provider.minimumZoom, 0);
    });

    test('callers arriving together share one load', () async {
      var requests = 0;
      final basemap = Basemap(client: MockClient((_) async {
        requests++;
        return http.Response(_tileJson, 200);
      }));
      final results = await Future.wait([basemap.ensureLoaded(), basemap.ensureLoaded()]);
      expect(results, [true, true]);
      expect(requests, 1);
    });

    test('offline, the last TileJSON read is used, so cached tiles still draw', () async {
      final online = Basemap(client: MockClient((_) async => http.Response(_tileJson, 200)));
      expect(await online.ensureLoaded(), isTrue);
      await Future<void>.delayed(Duration.zero); // the remember is not awaited

      final offline = Basemap(client: MockClient((request) async => throw http.ClientException('offline')));
      expect(await offline.ensureLoaded(), isTrue);
      expect(offline.style.value!.providers.get('openmaptiles').maximumZoom, 14);
    });

    test('offline on a first launch it fails without throwing, and the next call tries again', () async {
      var requests = 0;
      var online = false;
      final basemap = Basemap(client: MockClient((_) async {
        requests++;
        if (!online) throw http.ClientException('offline');
        return http.Response(_tileJson, 200);
      }));

      expect(await basemap.ensureLoaded(), isFalse);
      expect(basemap.style.value, isNull);

      online = true;
      expect(await basemap.ensureLoaded(), isTrue);
      expect(requests, 2);
    });

    test('an answer that is not a TileJSON is a failure, not a crash', () async {
      final basemap = Basemap(client: MockClient((_) async => http.Response('<html>down</html>', 200)));
      expect(await basemap.ensureLoaded(), isFalse);
      final notFound = Basemap(client: MockClient((_) async => http.Response('', 503)));
      expect(await notFound.ensureLoaded(), isFalse);
    });

    test('the fingerprint moves with any edit to the style', () {
      expect(Basemap.fingerprint('{"a":1}'), Basemap.fingerprint('{"a":1}'));
      expect(Basemap.fingerprint('{"a":1}'), isNot(Basemap.fingerprint('{"a":2}')));
    });
  });

  testWidgets('offline, the map draws no basemap, keeps retrying, and stops when it closes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final style = (await tester.runAsync(() => rootBundle.loadString(kBasemapStyle)))!;
    var requests = 0;
    final basemap = Basemap(
      bundle: _TextBundle(style),
      client: MockClient((_) async {
        requests++;
        throw http.ClientException('offline');
      }),
    );
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: MpBasemap(basemap: basemap),
    ));
    await tester.pump();
    expect(requests, 1);
    expect(find.byType(VectorTileLayer), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    expect(requests, 2, reason: 'first retry after 5s');
    await tester.pump(const Duration(seconds: 9));
    expect(requests, 2, reason: 'then 10s');
    await tester.pump(const Duration(seconds: 1));
    expect(requests, 3);

    // Disposing the map cancels the pending retry; a timer left behind would
    // fail this test.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
    expect(requests, 3);
  });
}

/// The style's text without the asset machinery, whose loads never finish
/// inside testWidgets' fake clock.
class _TextBundle extends CachingAssetBundle {
  _TextBundle(this.text);
  final String text;

  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(utf8.encode(text));

  @override
  Future<String> loadString(String key, {bool cache = true}) => Future.value(text);
}
