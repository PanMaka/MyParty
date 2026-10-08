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
class RsvpParty {
  final String partyId;
  final String title;
  final DateTime startsAt;

  /// Null when the host gave no end time. Whether such a party is over is the
  /// server's call (the six-hour grace, gotcha 21), made in `get_my_parties`
  /// by the same rule as the map — never re-decided from this field.
  final DateTime? endsAt;
  final bool isPrivate;
  final int goingCount;
  final int interestedCount;

  /// 'going' / 'interested', or null when the viewer has not answered —
  /// a party they host or were invited to and have not RSVP'd to yet.
  final String? rsvpStatus;
  final bool isHost;
  final bool isInvited;

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
  });

  /// One row of `get_my_parties`, which merges the three sources server-side
  /// — one row per party, flags already combined.
  ///
  /// The counters are `int?` on the wire only defensively: the RPC passes
  /// them through for every row, private included, as the table selects it
  /// replaced did. A private row renders no count either way.
  factory RsvpParty.fromRow(Map<String, dynamic> row) {
    return RsvpParty(
      partyId: row['party_id'] as String,
      title: row['title'] as String,
      startsAt: DateTime.parse(row['starts_at'] as String).toLocal(),
      endsAt: row['ends_at'] == null ? null : DateTime.parse(row['ends_at'] as String).toLocal(),
      isPrivate: row['is_private'] as bool,
      goingCount: (row['going_count'] as int?) ?? 0,
      interestedCount: (row['interested_count'] as int?) ?? 0,
      rsvpStatus: row['my_rsvp_status'] as String?,
      isHost: (row['is_host'] as bool?) ?? false,
      isInvited: (row['is_invited'] as bool?) ?? false,
    );
  }
}
