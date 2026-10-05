/// A party the current user has RSVP'd to, joined from `rsvps` + `parties`.
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
  final String rsvpStatus;

  const RsvpParty({
    required this.partyId,
    required this.title,
    required this.startsAt,
    this.endsAt,
    required this.isPrivate,
    required this.goingCount,
    required this.interestedCount,
    required this.rsvpStatus,
  });

  factory RsvpParty.fromRow(Map<String, dynamic> row) {
    final party = row['parties'] as Map<String, dynamic>;
    return RsvpParty(
      partyId: party['id'] as String,
      title: party['title'] as String,
      startsAt: DateTime.parse(party['starts_at'] as String).toLocal(),
      endsAt: party['ends_at'] == null ? null : DateTime.parse(party['ends_at'] as String).toLocal(),
      isPrivate: party['is_private'] as bool,
      goingCount: party['going_count'] as int,
      interestedCount: party['interested_count'] as int,
      rsvpStatus: row['status'] as String,
    );
  }
}
