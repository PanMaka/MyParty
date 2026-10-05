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

  /// Null when the host gave no end time — which the map treats as "not over"
  /// (gotcha 21), and so does MY PARTIES, so a party you can still see and
  /// answer on the map is also in your list.
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

  /// A row of `rsvps` with its party embedded as `parties`.
  factory RsvpParty.fromRow(Map<String, dynamic> row) =>
      RsvpParty.fromParty(row['parties'] as Map<String, dynamic>, rsvpStatus: row['status'] as String);

  /// A `parties` row, from whichever of the three sources found it.
  factory RsvpParty.fromParty(
    Map<String, dynamic> party, {
    String? rsvpStatus,
    bool isHost = false,
    bool isInvited = false,
  }) {
    return RsvpParty(
      partyId: party['id'] as String,
      title: party['title'] as String,
      startsAt: DateTime.parse(party['starts_at'] as String).toLocal(),
      endsAt: party['ends_at'] == null ? null : DateTime.parse(party['ends_at'] as String).toLocal(),
      isPrivate: party['is_private'] as bool,
      goingCount: party['going_count'] as int,
      interestedCount: party['interested_count'] as int,
      rsvpStatus: rsvpStatus,
      isHost: isHost,
      isInvited: isInvited,
    );
  }

  /// This row with what [other] — the same party, found by another source —
  /// knows about the viewer's part in it.
  RsvpParty mergedWith(RsvpParty other) => RsvpParty(
        partyId: partyId,
        title: title,
        startsAt: startsAt,
        endsAt: endsAt,
        isPrivate: isPrivate,
        goingCount: goingCount,
        interestedCount: interestedCount,
        rsvpStatus: rsvpStatus ?? other.rsvpStatus,
        isHost: isHost || other.isHost,
        isInvited: isInvited || other.isInvited,
      );
}
