import 'map_party_pin.dart';

/// One row of MY PARTIES: a party the current user is part of.
///
/// "Part of" is any of three things, and a party can be more than one: the
/// viewer RSVP'd to it ([rsvpStatus]), hosts it ([isHost]), or holds an
/// invitation to it ([isInvited]). Host and invitee are exactly who
/// `can_chat_in_party` lets into a private party's chat, so with all three in
/// the list every group chat in the Messages tab has an entry here too.
///
/// Still named for the rsvp it started as; the shape is unchanged for an
/// rsvp-only row.
///
/// Tapping a row opens [MapPinSheet] on [pin] — the same sheet a map pin or a
/// search hit opens, fed from the same columns (`get_my_parties` joins the
/// payload parity in 20_party_search since 20261008152601).
class RsvpParty {
  final String partyId;
  final String title;
  final DateTime startsAt;

  /// Null when the host gave no end time. Whether such a party is over is the
  /// server's call (the six-hour grace, gotcha 21), made in `get_my_parties`
  /// by the same rule as the map — never re-decided from this field.
  final DateTime? endsAt;
  final bool isPrivate;

  /// NULL on a private party, as on every surface (20260825090051) — the
  /// server sends no number, so there is none to coalesce to.
  final int? goingCount;
  final int? interestedCount;

  /// 'going' / 'interested', or null when the viewer has not answered —
  /// a party they host or were invited to and have not RSVP'd to yet.
  final String? rsvpStatus;
  final bool isHost;
  final bool isInvited;

  /// This party as [MapPinSheet] takes it. Parsed from the same row by the
  /// same factory the map and search use, so the sheet cannot tell which
  /// screen it was opened from.
  final MapPartyPin pin;

  const RsvpParty({
    required this.partyId,
    required this.title,
    required this.startsAt,
    this.endsAt,
    required this.isPrivate,
    required this.goingCount,
    required this.interestedCount,
    this.rsvpStatus,
    this.isHost = false,
    this.isInvited = false,
    required this.pin,
  });

  /// One row of `get_my_parties`, which merges the three sources server-side
  /// — one row per party, flags already combined.
  factory RsvpParty.fromRow(Map<String, dynamic> row) {
    return RsvpParty(
      partyId: row['party_id'] as String,
      title: row['title'] as String,
      startsAt: DateTime.parse(row['starts_at'] as String).toLocal(),
      endsAt: row['ends_at'] == null ? null : DateTime.parse(row['ends_at'] as String).toLocal(),
      isPrivate: row['is_private'] as bool,
      goingCount: row['going_count'] as int?,
      interestedCount: row['interested_count'] as int?,
      rsvpStatus: row['my_rsvp_status'] as String?,
      isHost: (row['is_host'] as bool?) ?? false,
      isInvited: (row['is_invited'] as bool?) ?? false,
      pin: MapPartyPin.fromRpcRow(row, fallbackId: row['party_id'] as String),
    );
  }
}
