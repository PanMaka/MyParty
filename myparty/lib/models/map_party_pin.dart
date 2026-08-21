/// A party pin sourced from the live `get_parties_near_user` Supabase RPC.
///
/// Every field below is a column that RPC actually returns. The previous
/// version of this class read `attendee_count`/`pop`/`population` and
/// `live`/`is_live` behind `??` fallbacks — none of which the RPC has ever
/// emitted — so `attendeeCount` was always 0 and `live` always false: every
/// pin drew the same width and the "live" pulse ring never fired once.
/// `going_count` had been in the payload, unread, since it was added.
///
/// The fallback chain is gone rather than extended. A `??` over three names the
/// server does not use cannot fail loudly, which is exactly why the bug
/// survived; a cast against the one real column name throws if the payload
/// changes shape, and a test catches it.
class MapPartyPin {
  final String id;
  final double lat;
  final double lng;
  final String title;
  final bool isPrivate;

  /// Both RSVP counters, kept separate rather than pre-collapsed into one
  /// number — which of the two a surface shows depends on whether the party is
  /// live, and that answer changes while the pin is on screen.
  final int goingCount;
  final int interestedCount;

  /// `endsAt` is nullable in the schema and the host wizard does not require
  /// it, so "no stated end" is a real state and not a parse failure. See the
  /// map query's open `ends_at` decision in CLAUDE.md — a null here means the
  /// party has no end the server can filter on either.
  final DateTime? startsAt;
  final DateTime? endsAt;

  /// Neighbourhood label written by the host; null means they did not say.
  final String? area;

  /// A storage key into the private `party-covers` bucket, never a URL —
  /// resolving it needs a signed URL from the repository layer, the same
  /// arrangement as `profiles.avatar_path`.
  final String? coverPath;

  const MapPartyPin({
    required this.id,
    required this.lat,
    required this.lng,
    required this.title,
    required this.isPrivate,
    this.goingCount = 0,
    this.interestedCount = 0,
    this.startsAt,
    this.endsAt,
    this.area,
    this.coverPath,
  });

  factory MapPartyPin.fromRpcRow(Map<String, dynamic> row, {required String fallbackId}) {
    return MapPartyPin(
      id: (row['party_id'] ?? fallbackId).toString(),
      lat: (row['lat'] as num).toDouble(),
      lng: (row['lon'] as num).toDouble(),
      title: (row['title'] as String?) ?? 'Πάρτι',
      isPrivate: (row['is_private'] as bool?) ?? false,
      // `?? 0` is the true value here: zero really is "nobody yet". The
      // nullable fields below get no such default, because there is no true
      // value for an unstated end time, neighbourhood or cover.
      goingCount: (row['going_count'] as int?) ?? 0,
      interestedCount: (row['interested_count'] as int?) ?? 0,
      startsAt: _parseTimestamp(row['starts_at']),
      endsAt: _parseTimestamp(row['ends_at']),
      area: row['area'] as String?,
      coverPath: row['cover_path'] as String?,
    );
  }

  static DateTime? _parseTimestamp(Object? value) {
    if (value is! String) return null;
    return DateTime.parse(value).toLocal();
  }

  /// Whether the party is happening at [now]: it has started, and either has
  /// no stated end or has not reached it.
  ///
  /// Takes the clock as an argument rather than reading it, so a test can
  /// assert both sides of the boundary without sleeping. [live] is the
  /// convenience form.
  ///
  /// This is computed on the CLIENT on purpose, from the two timestamps, and
  /// is not a boolean the RPC hands over. A server-computed flag is true as of
  /// the query and stays true in the widget for as long as the pin is held —
  /// and the map holds its pins across a 500ms-debounced pan, so a party that
  /// starts between two fetches would keep rendering as not-live until the
  /// user happened to move the map.
  bool liveAt(DateTime now) {
    final start = startsAt;
    if (start == null || start.isAfter(now)) return false;
    final end = endsAt;
    return end == null || end.isAfter(now);
  }

  bool get live => liveAt(DateTime.now());

  /// The number a pin prints, and it is a different number depending on the
  /// tense: a live party reports who is *inside* it ("N μέσα"), one that has
  /// not started reports who is *interested* ("N ενδ."). Both surfaces —
  /// [MpMapPin] and [MapPinSheet] — pair this with [live], so the count and
  /// its label can never disagree about which of the two it is.
  int attendeeCountAt(DateTime now) => liveAt(now) ? goingCount : interestedCount;

  int get attendeeCount => attendeeCountAt(DateTime.now());

  /// True only when the host uploaded a cover, mirroring [PartySummary].
  bool get hasCover => coverPath != null;
}
