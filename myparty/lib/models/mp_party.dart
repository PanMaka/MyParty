enum MpPartyType { public, private }

/// Mock party data, ported verbatim from the design's `PARTIES` object.
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
  });

  bool get isPrivate => type == MpPartyType.private;
}

const Map<String, MpParty> mpParties = {
  'taratsa': MpParty(
    id: 'taratsa',
    name: 'Ταράτσα στο Κουκάκι',
    type: MpPartyType.private,
    host: 'Δημήτρης Παπαδέας',
    hostSub: 'φίλος σου · 3ο πάρτι φέτος',
    sub: 'Ιδιωτικό · σε κάλεσε ο Δημήτρης',
    time: 'Απόψε 23:30',
    dist: '400 μ.',
    crowd: '24 μέσα τώρα',
    live: true,
    imgLabel: 'φωτό ταράτσας',
    posters: '11 άτομα ανεβάζουν',
    desc:
        'Φέρτε ό,τι πίνετε, έχει ηχείο και θέα Ακρόπολη. Ξεκινάμε 23:30, μη μου έρθετε 01:00.',
    note:
        'Το βλέπουν μόνο οι 24 καλεσμένοι. Η διεύθυνση δεν φαίνεται πουθενά αλλού.',
    lat: 37.9636,
    lng: 23.7249,
    pop: 24,
  ),
  'vinyl': MpParty(
    id: 'vinyl',
    name: 'Techno Δευτέρα · DJ Ίρις',
    type: MpPartyType.public,
    host: 'Vinyl Room',
    hostSub: 'χώρος · 4.2χ ακόλουθοι',
    sub: 'Δημόσιο · Vinyl Room, Ψυρρή',
    time: 'Απόψε 23:00',
    dist: '1,1 χλμ.',
    crowd: '180 μέσα · 312 ενδιαφέρονται',
    live: true,
    imgLabel: 'clip dancefloor',
    posters: '46 άτομα ανεβάζουν',
    desc:
        'Τρεις ώρες σετ από την Ίρις, μετά open decks μέχρι το πρωί. Είσοδος 8€ με ποτό, μέχρι τις 00:30 guest list.',
    note: 'Δημόσιο πάρτι — το βλέπουν όλοι στον χάρτη.',
    lat: 37.9784,
    lng: 23.7247,
    pop: 180,
  ),
  'maria': MpParty(
    id: 'maria',
    name: 'Γενέθλια Μαρίας',
    type: MpPartyType.private,
    host: 'Μαρία Ζέρβα',
    hostSub: 'φίλη φίλου · 1ο πάρτι',
    sub: 'Ιδιωτικό · σε κάλεσε η Μαρία',
    time: 'Απόψε 22:00',
    dist: '2,3 χλμ.',
    crowd: '31 μέσα',
    live: true,
    imgLabel: 'φωτό τούρτας',
    posters: '9 άτομα ανεβάζουν',
    desc: '25 χρονών. Πέμπτος όροφος, χτυπήστε δυνατά το κουδούνι γιατί δεν ακούμε.',
    note: 'Το βλέπουν μόνο οι καλεσμένοι της Μαρίας.',
    lat: 37.9866,
    lng: 23.7357,
    pop: 31,
  ),
  'kapsimo': MpParty(
    id: 'kapsimo',
    name: 'Kápsimo x Λευτέρης',
    type: MpPartyType.public,
    host: 'Kápsimo',
    hostSub: 'χώρος · 8.9χ ακόλουθοι',
    sub: 'Δημόσιο · Kápsimo, Γκάζι',
    time: 'Απόψε 00:00',
    dist: '1,6 χλμ.',
    crowd: '96 ενδιαφέρονται',
    live: false,
    imgLabel: 'poster Kápsimo',
    posters: '23 άτομα ανεβάζουν',
    desc: 'Disco και ιταλικά, από τα μεσάνυχτα. Ελεύθερη είσοδος μέχρι τη 01:00.',
    note: 'Δημόσιο πάρτι — το βλέπουν όλοι στον χάρτη.',
    lat: 37.9771,
    lng: 23.7148,
    pop: 96,
  ),
  'anodos': MpParty(
    id: 'anodos',
    name: 'Anodos Rooftop · sunset set',
    type: MpPartyType.public,
    host: 'Anodos Rooftop',
    hostSub: 'χώρος · 2.1χ ακόλουθοι',
    sub: 'Δημόσιο · Μοναστηράκι',
    time: 'Παρ 8 Αυγ, 21:00',
    dist: '900 μ.',
    crowd: '54 ενδιαφέρονται',
    live: false,
    imgLabel: 'φωτό ταράτσας ηλιοβασίλεμα',
    posters: '12 άτομα ανεβάζουν',
    desc:
        'Ήπιο σετ με θέα την Ακρόπολη, από τις 21:00 μέχρι τη 01:00. Κρατήσεις για τραπέζια.',
    note: 'Δημόσιο πάρτι — το βλέπουν όλοι στον χάρτη.',
    lat: 37.9752,
    lng: 23.7281,
    pop: 54,
  ),
  'nefeli': MpParty(
    id: 'nefeli',
    name: 'Μετακόμιση Νεφέλης',
    type: MpPartyType.private,
    host: 'Νεφέλη Ρίζου',
    hostSub: 'φίλη σου · 2ο πάρτι φέτος',
    sub: 'Ιδιωτικό · σε κάλεσε η Νεφέλη',
    time: 'Σάβ 16 Αυγ, 22:00',
    dist: '1,9 χλμ.',
    crowd: '14 πάνε',
    live: false,
    imgLabel: 'φωτό σαλονιού',
    posters: 'κανείς ακόμα',
    desc: 'Καινούριο σπίτι στα Πετράλωνα, φέρτε κάτι για το ψυγείο. Γάτα μέσα, κλείνετε την μπαλκονόπορτα.',
    note: 'Το βλέπουν μόνο οι 20 καλεσμένοι.',
    lat: 37.9681,
    lng: 23.7112,
    pop: 14,
  ),
};
