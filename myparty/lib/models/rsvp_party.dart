/// A party the current user has RSVP'd to, joined from `rsvps` + `parties`.
class RsvpParty {
  final String partyId;
  final String title;
  final DateTime startsAt;
  final bool isPrivate;
  final int goingCount;
  final int interestedCount;
  final String rsvpStatus;

  const RsvpParty({
    required this.partyId,
    required this.title,
    required this.startsAt,
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
      isPrivate: party['is_private'] as bool,
      goingCount: party['going_count'] as int,
      interestedCount: party['interested_count'] as int,
      rsvpStatus: row['status'] as String,
    );
  }
}
