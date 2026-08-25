enum MpPartyType { public, private }

/// Mock party data, ported from the design's `PARTIES` object and since
/// translated to English along with the parties tab that renders it.
///
/// The strings here are content, not chrome: `time`, `dist` and `crowd` are
/// pre-baked display text rather than values a formatter is ever run over, so
/// they are the one place a relative time like 'Tonight 22:00' is a literal.
/// They go away with the file when parties come off Supabase for real.
/// Greek personal and venue names are transliterated, not replaced -- the
/// people and the neighbourhoods stay Athenian, only the UI language moved.
class MpParty {
  final String id;
  final String name;
  final MpPartyType type;
  final String host;
  final String hostSub;
  final String sub;
  final String time;
  final String dist;
  final String crowd;
  final bool live;
  final String imgLabel;
  final String posters;
  final String desc;
  final String note;
  final double lat;
  final double lng;
  final int pop;
  final int sortKey;
  final int commentCount;

  const MpParty({
    required this.id,
    required this.name,
    required this.type,
    required this.host,
    required this.hostSub,
    required this.sub,
    required this.time,
    required this.dist,
    required this.crowd,
    required this.live,
    required this.imgLabel,
    required this.posters,
    required this.desc,
    required this.note,
    required this.lat,
    required this.lng,
    required this.pop,
    required this.sortKey,
    required this.commentCount,
  });

  bool get isPrivate => type == MpPartyType.private;
}


const Map<String, MpParty> mpParties = {
  'taratsa': MpParty(
    id: 'taratsa',
    name: 'Rooftop in Koukaki',
    type: MpPartyType.private,
    host: 'Dimitris Papadeas',
    hostSub: 'your friend · 3rd party this year',
    sub: 'Private · Dimitris invited you',
    time: 'Tonight 23:30',
    dist: '400 m',
    crowd: '24 inside now',
    live: true,
    imgLabel: 'rooftop photo',
    posters: '11 people posting',
    desc:
        'Bring whatever you drink, there’s a speaker and an Acropolis view. We start at 23:30, don’t turn up at 01:00.',
    note:
        'Only the 24 guests can see this. The address shows up nowhere else.',
    lat: 37.9636,
    lng: 23.7249,
    pop: 24,
    sortKey: 3,
    commentCount: 61,
  ),
  'vinyl': MpParty(
    id: 'vinyl',
    name: 'Techno Monday · DJ Iris',
    type: MpPartyType.public,
    host: 'Vinyl Room',
    hostSub: 'venue · 4.2k followers',
    sub: 'Public · Vinyl Room, Psyrri',
    time: 'Tonight 23:00',
    dist: '1.1 km',
    crowd: '180 inside · 312 interested',
    live: true,
    imgLabel: 'dancefloor clip',
    posters: '46 people posting',
    desc:
        'Three-hour set from Iris, then open decks until morning. 8€ entry with a drink, guest list until 00:30.',
    note: 'Public party — everyone on the map can see it.',
    lat: 37.9784,
    lng: 23.7247,
    pop: 180,
    sortKey: 2,
    commentCount: 34,
  ),
  'maria': MpParty(
    id: 'maria',
    name: 'Maria’s Birthday',
    type: MpPartyType.private,
    host: 'Maria Zerva',
    hostSub: 'friend of a friend · 1st party',
    sub: 'Private · Maria invited you',
    time: 'Tonight 22:00',
    dist: '2.3 km',
    crowd: '31 inside',
    live: true,
    imgLabel: 'cake photo',
    posters: '9 people posting',
    desc: 'Turning 25. Fifth floor, ring the bell hard because we can’t hear it.',
    note: 'Only Maria’s guests can see this.',
    lat: 37.9866,
    lng: 23.7357,
    pop: 31,
    sortKey: 1,
    commentCount: 12,
  ),
  'kapsimo': MpParty(
    id: 'kapsimo',
    name: 'Kápsimo x Lefteris',
    type: MpPartyType.public,
    host: 'Kápsimo',
    hostSub: 'venue · 8.9k followers',
    sub: 'Public · Kápsimo, Gazi',
    time: 'Tonight 00:00',
    dist: '1.6 km',
    crowd: '96 interested',
    live: false,
    imgLabel: 'Kápsimo poster',
    posters: '23 people posting',
    desc: 'Disco and Italo, from midnight. Free entry until 01:00.',
    note: 'Public party — everyone on the map can see it.',
    lat: 37.9771,
    lng: 23.7148,
    pop: 96,
    sortKey: 4,
    commentCount: 27,
  ),
  'anodos': MpParty(
    id: 'anodos',
    name: 'Anodos Rooftop · sunset set',
    type: MpPartyType.public,
    host: 'Anodos Rooftop',
    hostSub: 'venue · 2.1k followers',
    sub: 'Public · Monastiraki',
    time: 'Fri 8 Aug, 21:00',
    dist: '900 m',
    crowd: '54 interested',
    live: false,
    imgLabel: 'rooftop sunset photo',
    posters: '12 people posting',
    desc:
        'Easy set with a view of the Acropolis, 21:00 until 01:00. Tables by reservation.',
    note: 'Public party — everyone on the map can see it.',
    lat: 37.9752,
    lng: 23.7281,
    pop: 54,
    sortKey: 5,
    commentCount: 19,
  ),
  'nefeli': MpParty(
    id: 'nefeli',
    name: 'Nefeli’s Housewarming',
    type: MpPartyType.private,
    host: 'Nefeli Rizou',
    hostSub: 'your friend · 2nd party this year',
    sub: 'Private · Nefeli invited you',
    time: 'Sat 16 Aug, 22:00',
    dist: '1.9 km',
    crowd: '14 going',
    live: false,
    imgLabel: 'living room photo',
    posters: 'nobody yet',
    desc: 'New place in Petralona, bring something for the fridge. Cat inside, keep the balcony door shut.',
    note: 'Only the 20 guests can see this.',
    lat: 37.9681,
    lng: 23.7112,
    pop: 14,
    sortKey: 6,
    commentCount: 6,
  ),
};
