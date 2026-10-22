import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

// Address search for the host wizard, through MapTiler's Geocoding API.
//
// Runs on the HOST's device, about the host's own party: MapTiler receives
// what the host types and where the host puts the pin, and nothing about any
// guest. That is a decision, reversed on purpose in Phase 42 — see
// docs/backlog.md §3 — not an accident to be "fixed" by removing it.
//
// The map tiles are OpenFreeMap's, not MapTiler's; only search goes here
// (docs/backlog.md 1.34). The key is `MAPTILER_API_KEY` in `.env`, read
// guarded because widget tests never load `.env`. Without one, every
// call answers [GeocodeFailure.unavailable] without touching the network, and
// the host places the pin by hand.
//
// Never throws. Every failure is a [GeocodeFailure] the UI can name.

/// One place a search or a reverse lookup found.
@immutable
class GeocodedPlace {
  const GeocodedPlace({required this.label, required this.point, this.area});

  /// One line, ready for `parties.address`: "Αισχύλου 12, 105 54 Αθήνα",
  /// the country dropped. At most [maxAddressLength] characters.
  final String label;

  /// Where MapTiler puts it. Becomes the pin, which the host can still move.
  final LatLng point;

  /// The neighbourhood ("Ψυρρή"), or failing that the municipality, for
  /// pre-filling `parties.area`. At most [maxAreaLength] characters.
  final String? area;

  @override
  bool operator ==(Object other) =>
      other is GeocodedPlace && other.label == label && other.point == point && other.area == area;

  @override
  int get hashCode => Object.hash(label, point, area);

  @override
  String toString() => 'GeocodedPlace($label, $point, $area)';
}

/// `parties_address_one_line`: 200 characters.
const maxAddressLength = 200;

/// `parties_area_one_short_line`: 80 characters.
const maxAreaLength = 80;

/// Why a lookup gave no places. Each one says something different to the host.
enum GeocodeFailure {
  /// No connection, or no answer in time.
  network,

  /// No key, or MapTiler refused it (403): nothing the host can retry.
  unavailable,

  /// Rate-limited, a server error, or an answer we could not read. MapTiler
  /// documents no 429 or quota status, so anything not 200/400/403 lands here.
  busy,
}

/// What the host is told for each [GeocodeFailure], and for an empty search.
/// Every message ends with the way out: placing the pin by hand.
String geocodeFailureMessage(GeocodeFailure failure) => switch (failure) {
      GeocodeFailure.network => 'No connection. Check your internet, or place the pin on the map.',
      GeocodeFailure.unavailable => 'Address search isn’t available right now. Place the pin on the map instead.',
      GeocodeFailure.busy => 'Address search is busy. Try again in a moment, or place the pin on the map.',
    };

const geocodeNoResultsMessage = 'No matches. Try another spelling, or place the pin on the map.';

/// The line under every address field, required by our own reading of
/// MapTiler's terms and by the decision recorded in docs/backlog.md §3.
const geocodeAttribution = 'Address search is provided by MapTiler. © OpenStreetMap contributors';

/// Places, or why there are none. An empty [GeocodeFound] is "no matches",
/// which is not a failure: the service answered.
sealed class GeocodeResult {
  const GeocodeResult();
}

class GeocodeFound extends GeocodeResult {
  const GeocodeFound(this.places);
  final List<GeocodedPlace> places;
}

class GeocodeFailed extends GeocodeResult {
  const GeocodeFailed(this.failure);
  final GeocodeFailure failure;
}

class GeocodingService {
  GeocodingService({http.Client? client, String? apiKey, this.timeout = const Duration(seconds: 8)})
      : _client = client ?? http.Client(),
        _apiKey = apiKey ?? _keyFromEnv();

  final http.Client _client;
  final String _apiKey;
  final Duration timeout;

  /// Read guarded: widget tests never load .env.
  static String _keyFromEnv() =>
      dotenv.isInitialized ? (dotenv.maybeGet('MAPTILER_API_KEY') ?? '').trim() : '';

  static const _host = 'api.maptiler.com';

  /// Forward search, as the host types. [near] biases the ranking (the pin,
  /// the device, or central Athens); it does not restrict, so a party abroad
  /// is still findable. Greek first, then English, for the labels — what the
  /// host types can be either.
  Future<GeocodeResult> search(String query, {required LatLng near, int limit = 5}) {
    final q = query.trim();
    if (q.isEmpty) return Future.value(const GeocodeFound([]));
    return _get(
      // One path segment: Uri encodes it exactly once, '/' included.
      '$q.json',
      {
        'proximity': '${near.longitude},${near.latitude}',
        'autocomplete': 'true',
        'limit': '$limit',
      },
    );
  }

  /// The address at the pin. MapTiler answers with the whole hierarchy, most
  /// specific first; only that first one is useful as an address.
  Future<GeocodeResult> reverse(LatLng point) async {
    final result = await _get(
      '${point.longitude},${point.latitude}.json',
      {'limit': '1'},
    );
    if (result is GeocodeFound && result.places.length > 1) {
      return GeocodeFound([result.places.first]);
    }
    return result;
  }

  /// GET `/geocoding/{segment}`. [segment] is one path segment, raw.
  Future<GeocodeResult> _get(String segment, Map<String, String> params) async {
    if (_apiKey.isEmpty) return const GeocodeFailed(GeocodeFailure.unavailable);
    final uri = Uri(
      scheme: 'https',
      host: _host,
      pathSegments: ['geocoding', segment],
      queryParameters: {...params, 'language': 'el,en', 'key': _apiKey},
    );
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(timeout);
    } on TimeoutException {
      return const GeocodeFailed(GeocodeFailure.network);
    } on SocketException {
      return const GeocodeFailed(GeocodeFailure.network);
    } on http.ClientException {
      return const GeocodeFailed(GeocodeFailure.network);
    } catch (e) {
      debugPrint('Geocoding failed: ${e.runtimeType}');
      return const GeocodeFailed(GeocodeFailure.network);
    }

    switch (response.statusCode) {
      case 200:
        try {
          final body = jsonDecode(utf8.decode(response.bodyBytes));
          return GeocodeFound(parseFeatureCollection(body));
        } catch (_) {
          return const GeocodeFailed(GeocodeFailure.busy);
        }
      // A query MapTiler will not take (too long, odd characters) has no
      // answer, which to the host is the same as no match.
      case 400:
        return const GeocodeFound([]);
      case 401:
      case 403:
        return const GeocodeFailed(GeocodeFailure.unavailable);
      default:
        return const GeocodeFailed(GeocodeFailure.busy);
    }
  }

  /// MapTiler's GeoJSON FeatureCollection → places. Features without a usable
  /// centre or name are skipped rather than failing the whole answer.
  @visibleForTesting
  static List<GeocodedPlace> parseFeatureCollection(Object? body) {
    if (body is! Map || body['features'] is! List) {
      throw const FormatException('not a FeatureCollection');
    }
    final places = <GeocodedPlace>[];
    for (final feature in body['features'] as List) {
      final place = parseFeature(feature);
      if (place != null) places.add(place);
    }
    return places;
  }

  @visibleForTesting
  static GeocodedPlace? parseFeature(Object? feature) {
    if (feature is! Map) return null;
    final center = feature['center'];
    if (center is! List || center.length < 2 || center[0] is! num || center[1] is! num) return null;
    final lon = (center[0] as num).toDouble();
    final lat = (center[1] as num).toDouble();
    if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) return null;

    final context = [
      for (final c in (feature['context'] is List ? feature['context'] as List : const []))
        if (c is Map && c['id'] is String && c['text'] is String) (id: c['id'] as String, text: c['text'] as String),
    ];
    final label = _label(feature, context);
    if (label == null) return null;

    return GeocodedPlace(label: label, point: LatLng(lat, lon), area: _area(feature, context));
  }

  /// `place_name` without its trailing country: "Αισχύλου 12, 105 54 Αθήνα,
  /// Ελλάδα" → "Αισχύλου 12, 105 54 Αθήνα". One line, capped for the column.
  static String? _label(Map feature, List<({String id, String text})> context) {
    var name = (feature['place_name'] as String?)?.trim() ?? '';
    if (name.isEmpty) name = (feature['text'] as String?)?.trim() ?? '';
    if (name.isEmpty) return null;

    final country = context.where((c) => c.id.startsWith('country.')).map((c) => c.text).firstOrNull;
    if (country != null && name.endsWith(', $country')) {
      name = name.substring(0, name.length - country.length - 2);
    }
    name = name.replaceAll(RegExp(r'[\r\n]+'), ' ');
    return name.length > maxAddressLength ? name.substring(0, maxAddressLength).trimRight() : name;
  }

  /// A neighbourhood when MapTiler has one ("Ψυρρή"), the municipality when
  /// it does not ("Ηλιούπολη"). Not the administrative "locality" ("1η
  /// Κοινότητα Αθηνών"), which is nobody's name for where they are going.
  static String? _area(Map feature, List<({String id, String text})> context) {
    final types = feature['place_type'] is List ? (feature['place_type'] as List) : const [];
    final ownText = (feature['text'] as String?)?.trim();
    // The result IS a neighbourhood (someone searched "Ψυρρή").
    if (ownText != null && ownText.isNotEmpty && (types.contains('place') || types.contains('neighbourhood'))) {
      return _capArea(ownText);
    }
    for (final prefix in const ['neighbourhood.', 'place.', 'municipality.']) {
      final hit = context.where((c) => c.id.startsWith(prefix)).firstOrNull;
      if (hit != null && hit.text.trim().isNotEmpty) return _capArea(hit.text.trim());
    }
    return null;
  }

  static String _capArea(String s) {
    final one = s.replaceAll(RegExp(r'[\r\n]+'), ' ');
    return one.length > maxAreaLength ? one.substring(0, maxAreaLength).trimRight() : one;
  }
}

/// The state of an as-you-type search, for a suggestions list to render.
sealed class GeocodeSearchState {
  const GeocodeSearchState();
}

/// Nothing to show: the field is empty, under [GeocodeSearchController.minChars],
/// or a suggestion was just chosen.
class GeocodeSearchIdle extends GeocodeSearchState {
  const GeocodeSearchIdle();
}

class GeocodeSearchLoading extends GeocodeSearchState {
  const GeocodeSearchLoading();
}

/// The latest answer. Empty [places] is "no matches".
class GeocodeSearchResults extends GeocodeSearchState {
  const GeocodeSearchResults(this.places);
  final List<GeocodedPlace> places;
}

class GeocodeSearchError extends GeocodeSearchState {
  const GeocodeSearchError(this.failure);
  final GeocodeFailure failure;
}

/// Debounces keystrokes into searches: nothing under [minChars], one request
/// per [debounce] of quiet, and an answer that arrives after a newer query
/// was typed is dropped, so the list can never show results for text that is
/// no longer in the field.
class GeocodeSearchController extends ValueNotifier<GeocodeSearchState> {
  GeocodeSearchController({
    required this.service,
    required this.near,
    this.debounce = const Duration(milliseconds: 400),
    this.minChars = 3,
  }) : super(const GeocodeSearchIdle());

  final GeocodingService service;

  /// Asked at search time, so the bias follows the pin as it moves.
  final Future<LatLng> Function() near;

  final Duration debounce;
  final int minChars;

  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  /// Call on every change of the field's text.
  void onQueryChanged(String text) {
    _timer?.cancel();
    final query = text.trim();
    final generation = ++_generation;
    if (query.length < minChars) {
      value = const GeocodeSearchIdle();
      return;
    }
    _timer = Timer(debounce, () => _run(query, generation));
  }

  /// Hides the list, e.g. once a suggestion was chosen. Also drops any answer
  /// still in flight.
  void clear() {
    _timer?.cancel();
    _generation++;
    value = const GeocodeSearchIdle();
  }

  Future<void> _run(String query, int generation) async {
    if (_disposed || generation != _generation) return;
    value = const GeocodeSearchLoading();
    final bias = await near();
    if (_disposed || generation != _generation) return;
    final result = await service.search(query, near: bias);
    if (_disposed || generation != _generation) return;
    value = switch (result) {
      GeocodeFound(:final places) => GeocodeSearchResults(places),
      GeocodeFailed(:final failure) => GeocodeSearchError(failure),
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
