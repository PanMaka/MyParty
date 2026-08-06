/// A party pin sourced from the live `get_parties_near_user` Supabase RPC.
/// Fields the RPC doesn't (yet) return fall back to sane defaults instead of
/// being guessed, since the real schema isn't finalized.
class MapPartyPin {
  final String id;
  final double lat;
  final double lng;
  final String title;
  final bool isPrivate;
  final int attendeeCount;
  final bool live;

  const MapPartyPin({
    required this.id,
    required this.lat,
    required this.lng,
    required this.title,
    required this.isPrivate,
    required this.attendeeCount,
    required this.live,
  });

  factory MapPartyPin.fromRpcRow(Map<String, dynamic> row, {required String fallbackId}) {
    return MapPartyPin(
      id: (row['id'] ?? row['party_id'] ?? fallbackId).toString(),
      lat: (row['lat'] as num).toDouble(),
      lng: (row['lon'] as num).toDouble(),
      title: (row['title'] ?? row['name'] ?? 'Πάρτι').toString(),
      isPrivate: (row['is_private'] ?? row['private'] ?? false) as bool,
      attendeeCount: ((row['attendee_count'] ?? row['pop'] ?? row['population'] ?? 0) as num).toInt(),
      live: (row['live'] ?? row['is_live'] ?? false) as bool,
    );
  }
}
