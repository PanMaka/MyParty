import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:myparty/services/geocoding_service.dart';

/// A [GeocodingService] with scripted answers and a record of every call, so
/// widget tests never reach MapTiler and can assert what was asked.
///
/// Answers synchronously-resolved futures, so a `pump` after the debounce is
/// enough to see results.
class FakeGeocoder extends GeocodingService {
  FakeGeocoder({
    this.places = const [],
    this.reversePlace,
    this.searchFailure,
    this.reverseFailure,
  }) : super(apiKey: 'test', client: MockClient((_) async => http.Response('unexpected', 500)));

  /// Every search answers these (or [searchFailure]).
  List<GeocodedPlace> places;

  /// Every reverse lookup answers this (or [reverseFailure]; null = nothing).
  GeocodedPlace? reversePlace;

  GeocodeFailure? searchFailure;
  GeocodeFailure? reverseFailure;

  final searches = <String>[];
  final reverses = <LatLng>[];

  @override
  Future<GeocodeResult> search(String query, {required LatLng near, int limit = 5}) async {
    searches.add(query);
    final failure = searchFailure;
    if (failure != null) return GeocodeFailed(failure);
    return GeocodeFound(places);
  }

  @override
  Future<GeocodeResult> reverse(LatLng point) async {
    reverses.add(point);
    final failure = reverseFailure;
    if (failure != null) return GeocodeFailed(failure);
    final place = reversePlace;
    return GeocodeFound(place == null ? const [] : [place]);
  }
}
