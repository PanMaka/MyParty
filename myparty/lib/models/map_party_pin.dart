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
  ///
  /// NULL for a private party, and nullable in the type for that reason.
  /// 20260825090051 stops both read RPCs transmitting attendance for private
  /// rows, so this is not "unknown" — it is "not answered for this row", and
  /// there is no default that would be honest. `0` in particular is a legible
  /// lie: it reads as "nobody is going" and is indistinguishable from a real
  /// empty party.
  ///
  /// The nullability is the point. A surface that forgets a private party has
  /// no count does not render a confident zero, it fails to compile.
  final int? goingCount;
  final int? interestedCount;

  /// `endsAt` is nullable in the schema and the host wizard does not require
  /// it, so "no stated end" is a real state and not a parse failure. See the
  /// map query's open `ends_at` decision in CLAUDE.md — a null here means the
  /// party has no end the server can filter on either.
  final DateTime? startsAt;
  final DateTime? endsAt;

  /// Neighbourhood label written by the host; null means they did not say.
  final String? area;

  /// The host's blurb. Null means they wrote none — an empty body, not a
  /// missing one — so the sheet omits the section rather than showing a gap.
  final String? description;

  /// The host, as both payloads report them. `hostUsername` comes from an
  /// INNER JOIN on `profiles` in both RPCs, so it is null only if the column
  /// itself is (see the tombstone rule in CLAUDE.md — a deleted host still
  /// has a scrubbed handle and still renders).
  final String? hostId;
  final String? hostUsername;

  /// The VIEWER's own RSVP — `'interested'`, `'going'`, or null for neither.
  ///
  /// A property of who is asking, unlike [goingCount] and [interestedCount]
  /// which are properties of the party. Kept as a string for the same reason
  /// [RsvpParty.rsvpStatus] is: nothing in the client branches on it yet
  /// beyond rendering, and an enum would be a wire contract to maintain for a
  /// value that currently only gets compared.
  final String? myRsvpStatus;

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
    this.goingCount,
    this.interestedCount,
    this.startsAt,
    this.endsAt,
    this.area,
    this.description,
    this.hostId,
    this.hostUsername,
    this.myRsvpStatus,
    this.coverPath,
  });

  factory MapPartyPin.fromRpcRow(Map<String, dynamic> row, {required String fallbackId}) {
    return MapPartyPin(
      id: (row['party_id'] ?? fallbackId).toString(),
      lat: (row['lat'] as num).toDouble(),
      lng: (row['lon'] as num).toDouble(),
      title: (row['title'] as String?) ?? 'Party',
      isPrivate: (row['is_private'] as bool?) ?? false,
      // No `?? 0` any more. On a PUBLIC row zero really is "nobody yet" and
      // the server sends it; on a private row the server sends null and that
      // is a different fact. Coalescing here would erase the distinction the
      // migration exists to create, one line below the comment explaining it.
      goingCount: row['going_count'] as int?,
      interestedCount: row['interested_count'] as int?,
      startsAt: _parseTimestamp(row['starts_at']),
      endsAt: _parseTimestamp(row['ends_at']),
      area: row['area'] as String?,
      // All four were in the payload and unread until the sheet needed them.
      // `description` and `my_rsvp_status` were map-only until
      // 20260824094606 added them to search_parties, so that both screens can
      // fill the same sheet — see the parity assertion in
      // 20_party_search.test.sql.
      description: row['description'] as String?,
      hostId: row['host_id'] as String?,
      hostUsername: row['host_username'] as String?,
      myRsvpStatus: row['my_rsvp_status'] as String?,
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

  /// Whether this pin reports attendance at all.
  ///
  /// True exactly when the party is public. Derived from the payload rather
  /// than from [isPrivate] so that the client's rule and the server's rule are
  /// the same rule: if a future migration suppressed counts for some other
  /// reason, every surface would follow without being edited.
  bool get hasCounts => goingCount != null && interestedCount != null;

  /// The number a pin prints, and it is a different number depending on the
  /// tense: a live party reports who is *inside* it ("N here now"), one that
  /// has not started reports who is *interested* ("N interested").
  ///
  /// Since 20260826093437 the second of those is a SUPERSET of the first —
  /// `interested_count` counts every rsvp, going included — so the pre-live
  /// number is now the larger one and the pin shrinks when the party starts.
  /// That is the intended reading (interest before, presence during), but it
  /// means the two are no longer disjoint sets and must never be summed. Both
  /// surfaces — [MpMapPin] and [MapPinSheet] — pair this with [live], so the
  /// count and its label can never disagree about which of the two it is.
  ///
  /// Null for a private party, all the way through: there is no count to
  /// print, so callers branch on null rather than being handed a zero.
  int? attendeeCountAt(DateTime now) => liveAt(now) ? goingCount : interestedCount;

  int? get attendeeCount => attendeeCountAt(DateTime.now());

  /// The number the MAP PIN prints and is sized by: `interested_count`, in
  /// every tense.
  ///
  /// Not [attendeeCountAt], which switches to `going_count` once a party is
  /// live. On the pin that made "Interested" a button that never moved the
  /// number for any party already under way — and since 20260826093437
  /// `interested_count` counts everyone who answered at all, going included,
  /// so it is the one number BOTH answers move. The tense split survives in
  /// [MapPinSheet], which has room to label each counter.
  ///
  /// Null for a private party, exactly as [attendeeCountAt] is.
  int? get pinCount => interestedCount;

  /// True only when the host uploaded a cover, mirroring [PartySummary].
  bool get hasCover => coverPath != null;

  /// This pin as it reads once the viewer's answer is [next] ('going',
  /// 'interested', or null for withdrawn) — the optimistic half of an RSVP.
  ///
  /// The deltas mirror `sync_party_rsvp_counters` exactly, and they are not
  /// symmetric, because `interested_count` INCLUDES everyone going
  /// (20260826093437):
  ///
  ///  * gaining a row moves interested; it moves going too if the row is going;
  ///  * a status FLIP moves going alone — the person was counted as
  ///    interested before the flip and still is after it;
  ///  * losing a row is the reverse of gaining it.
  ///
  /// A private pin's counts stay null: the server sends none, so there is
  /// nothing to adjust and inventing a number here would print one.
  MapPartyPin withRsvp(String? next) {
    final prev = myRsvpStatus;
    var going = goingCount;
    var interested = interestedCount;

    if (going != null && interested != null && prev != next) {
      if (prev == null) {
        interested += 1;
        if (next == 'going') going += 1;
      } else if (next == null) {
        interested -= 1;
        if (prev == 'going') going -= 1;
      } else {
        going += next == 'going' ? 1 : -1;
      }
    }

    return MapPartyPin(
      id: id,
      lat: lat,
      lng: lng,
      title: title,
      isPrivate: isPrivate,
      goingCount: going,
      interestedCount: interested,
      startsAt: startsAt,
      endsAt: endsAt,
      area: area,
      description: description,
      hostId: hostId,
      hostUsername: hostUsername,
      myRsvpStatus: next,
      coverPath: coverPath,
    );
  }
}
