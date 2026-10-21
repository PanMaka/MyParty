import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../theme/app_theme.dart';

/// The basemap every map in the app draws on: OpenFreeMap's vector tiles,
/// rendered on the device in MyParty's own dark style.
///
/// It replaced CARTO's `dark_all` raster tiles in Phase 47, because CARTO's
/// free basemaps are licensed for non-commercial use only. OpenFreeMap allows
/// commercial use, needs no key and has no request limit, and it has no
/// uptime guarantee either: if it goes away, the move is to host the same
/// OpenMapTiles-schema tiles ourselves and change one `url` in the style.

/// Where the style comes from. The ONE line to change for a different style:
/// an `assets/` path is read from the bundle, an `https://` URL is fetched
/// (sprites included) through vector_map_tiles' `StyleReader`.
///
/// Bundled by default, so the style ships and versions with the app and there
/// is nothing to host. The tiles still come from wherever the style's
/// `sources` point — OpenFreeMap's `/planet` TileJSON today.
const kBasemapStyle = 'assets/map/myparty-dark.json';

/// The style's `background` colour. Every map paints it before the first tile
/// arrives and wherever one never does, so a slow or offline basemap is a
/// plain dark map with its pins, never a white or grey flash.
/// `basemap_test.dart` holds it equal to the style's background layer.
const kBasemapBackground = Color(0xFF171827);

/// The deepest zoom the basemap draws, and so the deepest any map may go.
/// The vector layer renders nothing past its own maximum, where CARTO's raster
/// tiles just kept upscaling, so the maps are capped here rather than turning
/// blank under a long pinch. 20 is individual buildings.
const kBasemapMaxZoom = 20.0;

/// Loads the style once per app session and hands the same [Style] to every
/// map. Retrying is the caller's job: a failure leaves [style] null, and the
/// next [ensureLoaded] starts over.
class Basemap {
  Basemap({
    this.styleUri = kBasemapStyle,
    AssetBundle? bundle,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  })  : _bundle = bundle ?? rootBundle,
        _client = client ?? http.Client();

  /// The app's one instance. Shared so that opening the host wizard's picker
  /// after the map tab costs no second load.
  static final instance = Basemap();

  final String styleUri;
  final AssetBundle _bundle;
  final http.Client _client;
  final Duration timeout;

  /// The loaded style, or null until a load has succeeded.
  ValueListenable<Style?> get style => _style;
  final _style = ValueNotifier<Style?>(null);

  Future<bool>? _inFlight;

  /// Loads the style unless it already is. True once it is loaded.
  ///
  /// Concurrent callers share one load. Never throws: a failure is logged and
  /// answers false, and the map stays usable on [kBasemapBackground].
  Future<bool> ensureLoaded() {
    if (_style.value != null) return Future.value(true);
    return _inFlight ??= _load().then((style) {
      _style.value = style;
      return true;
    }, onError: (Object e) {
      debugPrint('Basemap style failed to load: $e');
      return false;
    }).whenComplete(() => _inFlight = null);
  }

  Future<Style> _load() async {
    if (styleUri.startsWith('https://')) {
      return StyleReader(uri: styleUri, httpHeaders: _headers).read();
    }
    final text = await _bundle.loadString(styleUri);
    final json = jsonDecode(text) as Map<String, dynamic>;
    // The rendered tiles are cached on disk for 30 days under the theme's id
    // and version. A version taken from the file's contents means an edited
    // style can never be drawn from tiles rendered in the old one.
    json['metadata'] = {...?json['metadata'] as Map<String, dynamic>?, 'version': fingerprint(text)};

    final providers = <String, VectorTileProvider>{};
    for (final MapEntry(:key, :value) in (json['sources'] as Map<String, dynamic>).entries) {
      if (value is Map<String, dynamic> && value['type'] == 'vector') {
        providers[key] = await _vectorSource(value);
      }
    }
    return Style(
      name: json['name'] as String?,
      theme: vtr.ThemeReader().read(json),
      providers: TileProviders(providers),
    );
  }

  /// A vector source: tiles inline, or a TileJSON `url` to read them from.
  ///
  /// OpenFreeMap's tile URLs carry the data release they belong to
  /// (`/planet/20261018_080001_pt/{z}/{x}/{y}.pbf`), so they cannot be written
  /// into the style; the TileJSON is what names the current release.
  Future<VectorTileProvider> _vectorSource(Map<String, dynamic> source) async {
    final url = source['url'];
    final tileJson = url is String ? await _tileJson(url) : source;
    final tiles = tileJson['tiles'];
    if (tiles is! List || tiles.isEmpty || tiles.first is! String) {
      throw FormatException('vector source has no tiles', url);
    }
    return NetworkVectorTileProvider(
      urlTemplate: tiles.first as String,
      minimumZoom: (tileJson['minzoom'] as num?)?.toInt() ?? 0,
      maximumZoom: (tileJson['maxzoom'] as num?)?.toInt() ?? 14,
      httpHeaders: _headers,
    );
  }

  /// The TileJSON at [url], remembered across launches. Offline, the last one
  /// read is used instead: the tiles themselves are in the file cache, keyed by
  /// position rather than URL, so a cold start with no connection still draws
  /// every area this device has looked at before.
  Future<Map<String, dynamic>> _tileJson(String url) async {
    final key = 'basemap.tilejson.$url';
    try {
      final response = await _client.get(Uri.parse(url), headers: _headers).timeout(timeout);
      if (response.statusCode != 200) throw http.ClientException('HTTP ${response.statusCode}', Uri.parse(url));
      final body = utf8.decode(response.bodyBytes);
      final json = jsonDecode(body) as Map<String, dynamic>;
      unawaited(_remember(key, body));
      return json;
    } catch (e) {
      final remembered = await _recall(key);
      if (remembered == null) rethrow;
      debugPrint('Basemap TileJSON unavailable ($e); using the last one read.');
      return jsonDecode(remembered) as Map<String, dynamic>;
    }
  }

  static Future<void> _remember(String key, String value) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, value);
    } catch (_) {}
  }

  static Future<String?> _recall(String key) async {
    try {
      return (await SharedPreferences.getInstance()).getString(key);
    } catch (_) {
      return null;
    }
  }

  static const _headers = {'User-Agent': 'com.myparty.app'};

  /// FNV-1a over the style's text: stable across runs and Dart versions,
  /// which `String.hashCode` does not promise.
  @visibleForTesting
  static String fingerprint(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

/// The basemap layer, for the first slot of a `FlutterMap`'s children so the
/// markers and overlays after it draw on top.
///
/// Draws nothing until the style has loaded; the map's own
/// [kBasemapBackground] shows meanwhile. A failed load is retried with backoff
/// (5s, 10s, 20s, then every 60s), straight away when the app comes back to
/// the foreground, and again whenever a map opens — which together are what
/// "retry when connectivity returns" amounts to without a connectivity plugin.
class MpBasemap extends StatefulWidget {
  const MpBasemap({super.key, this.basemap});

  /// Injectable for tests; the app uses [Basemap.instance].
  final Basemap? basemap;

  @override
  State<MpBasemap> createState() => _MpBasemapState();
}

class _MpBasemapState extends State<MpBasemap> with WidgetsBindingObserver {
  late final Basemap _basemap = widget.basemap ?? Basemap.instance;
  Timer? _retry;
  int _failures = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    _retry?.cancel();
    final loaded = await _basemap.ensureLoaded();
    if (!mounted || loaded) return;
    _failures++;
    final seconds = math.min(60, 5 * math.pow(2, _failures - 1).toInt());
    _retry = Timer(Duration(seconds: seconds), _load);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _basemap.style.value == null) {
      _failures = 0;
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Style?>(
      valueListenable: _basemap.style,
      builder: (context, style, _) {
        if (style == null) return const SizedBox.shrink();
        return VectorTileLayer(
          theme: style.theme,
          sprites: style.sprites,
          tileProviders: style.providers,
          // Rendered to images, then drawn like raster tiles: the plugin's
          // best frame rate, which matters more on a low-end phone than the
          // vector mode's crisper in-between zooms.
          layerMode: VectorTileLayerMode.raster,
          maximumZoom: kBasemapMaxZoom,
          // Caching is on by default and these are its defaults, spelled out:
          // raw tiles in memory, rendered tiles on disk for 30 days, so
          // panning back over an area downloads nothing.
          memoryTileCacheMaxSize: VectorTileLayer.defaultTileCacheMaxSize,
          fileCacheTtl: VectorTileLayer.defaultCacheTtl,
          fileCacheMaximumSizeInBytes: VectorTileLayer.defaultCacheMaxSize,
        );
      },
    );
  }
}

/// The credit OpenFreeMap, OpenMapTiles and OpenStreetMap require, for an
/// interactive map. A small pill that is always visible names OpenStreetMap;
/// tapping it opens the full credit, with the OpenStreetMap line linking to its
/// copyright page. [bottom] lifts it clear of whatever sits along the map's
/// lower edge — the popup opens upwards from there.
class MpBasemapAttribution extends StatelessWidget {
  const MpBasemapAttribution({super.key, this.bottom = 0});

  final double bottom;

  static final _osmCopyright = Uri.parse('https://www.openstreetmap.org/copyright');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: RichAttributionWidget(
        showFlutterMapAttribution: false,
        popupBackgroundColor: AppColors.sheet,
        openButton: (context, open) => _CreditPill(onTap: open),
        attributions: [
          const TextSourceAttribution('OpenFreeMap', textStyle: _creditStyle),
          const TextSourceAttribution('OpenMapTiles', textStyle: _creditStyle),
          TextSourceAttribution(
            'OpenStreetMap contributors',
            textStyle: _creditStyle.copyWith(decoration: TextDecoration.underline),
            onTap: () => launchUrl(_osmCopyright, mode: LaunchMode.externalApplication),
          ),
        ],
      ),
    );
  }

  static const _creditStyle = TextStyle(fontSize: 12, color: AppColors.text);
}

class _CreditPill extends StatelessWidget {
  const _CreditPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('basemap-attribution'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.bg.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(99),
        ),
        // RichAttributionWidget draws this at half opacity until it is open.
        child: const Text('© OpenStreetMap', style: TextStyle(fontSize: 10.5, color: AppColors.text)),
      ),
    );
  }
}

/// The same credit for a map too small, or too static, for a popup: one line
/// of text, for the host wizard's preview.
const kBasemapCreditShort = '© OpenFreeMap © OpenMapTiles © OpenStreetMap';
