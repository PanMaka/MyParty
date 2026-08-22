import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/hosted_parties.dart';
import '../models/map_party_pin.dart';
import '../models/party_summary.dart';
import '../models/rsvp_party.dart';

/// Which end of the calendar a party list is asking for.
enum PartyWindow {
  /// Starting now or later, soonest first — a list you can still act on.
  upcoming,

  /// Already started, most recent first — a list you can only look back at.
  past,
}

/// Every widget-level Supabase call for parties/rsvps goes through here —
/// screens never call `Supabase.instance.client` directly.
class PartyRepository {
  PartyRepository({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  /// Resolved lazily, matching the other seven repositories. It used to be
  /// eager (`client ?? Supabase.instance.client` in the constructor), which
  /// meant a test double subclassing this constructed a real client before it
  /// could override anything — and under `flutter test` there is no
  /// initialized Supabase to construct one from. Nothing needed to fake a
  /// party until the profile screen did.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  String? get currentUserId => _client.auth.currentUser?.id;

  /// Creates a party and its initial invitations in one RPC call.
  /// `party` keys: title, description, lat, lon, starts_at (ISO 8601),
  /// is_private. Returns the new party's id.
  Future<String> createPartyWithInvites({
    required Map<String, dynamic> party,
    List<String> inviteeIds = const [],
  }) async {
    final id = await _client.rpc('create_party_with_invites', params: {
      'p_party': party,
      'p_invitee_ids': inviteeIds,
    });
    return id as String;
  }

  /// Parties the current user has RSVP'd to (interested or going),
  /// newest RSVP first. Bounded rather than keyset-paginated: this is a
  /// personal list, not an unbounded feed.
  Future<List<RsvpParty>> fetchMyRsvps() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return [];

    final rows = await _client
        .from('rsvps')
        .select(
          'status, parties!inner(id, title, starts_at, is_private, going_count, interested_count, status)',
        )
        .eq('user_id', userId)
        .eq('parties.status', 'published')
        .order('created_at', ascending: false)
        .limit(200);

    return (rows as List).map((row) => RsvpParty.fromRow(row as Map<String, dynamic>)).toList();
  }

  /// Parties hosted by [hostId], or by the current user when it is null.
  ///
  /// Resolves null from the session rather than accepting a substitute for
  /// `auth.uid()`, exactly as [ProfileRepository.fetchProfile] does.
  ///
  /// **Nothing here re-implements party visibility.** The `parties` SELECT
  /// policy is `can_access_party(id)`, so another user's private parties are
  /// already absent from the result — filtering again client-side would put a
  /// second copy of the rule in the app (CLAUDE.md #4) and it would drift.
  ///
  /// [publicOnly] is a different question and not redundant with that policy,
  /// the same way `not is_private` is not redundant with `can_user_access_party`
  /// in the proximity engine. RLS answers "may this viewer see it", which is
  /// true of a private party they hold an invitation to. A section headed
  /// "public parties they hosted" is asking something narrower, and rendering
  /// an invitation-only party under that heading would tell the viewer it was
  /// public when it is not.
  ///
  /// `status = 'published'` drops drafts and cancellations. A host can see
  /// their own drafts through the policy, but a draft is not something they
  /// are hosting yet, and a cancelled party is something they are not hosting
  /// any more.
  ///
  /// Bounded rather than keyset-paginated, like [fetchMyRsvps] and
  /// [SocialRepository.fetchFollowing]: this feeds a card and a three-tile
  /// strip, not an infinite scroll. `parties_host_id_idx` (20260818175437)
  /// covers the lookup.
  Future<List<PartySummary>> fetchHostedParties({
    String? hostId,
    required PartyWindow window,
    bool publicOnly = false,
    int limit = 12,
  }) async {
    final id = hostId ?? currentUserId;
    if (id == null) return [];

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final upcoming = window == PartyWindow.upcoming;

    final base = _client
        .from('parties')
        .select('id, title, starts_at, is_private, going_count, interested_count, max_capacity, cover_path, area')
        .eq('host_id', id)
        .eq('status', 'published');

    final scoped = publicOnly ? base.eq('is_private', false) : base;
    final windowed = upcoming ? scoped.gte('starts_at', nowIso) : scoped.lt('starts_at', nowIso);

    final rows = await windowed.order('starts_at', ascending: upcoming).limit(limit);

    return (rows as List)
        .map((row) => PartySummary.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  /// The profile's own party list: everything the CALLER hosts, already split
  /// into upcoming and past and already in display order.
  ///
  /// One RPC rather than two `.eq()` calls, and it replaces the deleted
  /// `fetchAttendedParties` — which read `rsvps` with an embedded
  /// `parties!inner(...)` and then sorted in Dart, because PostgREST's `order`
  /// on an embedded resource sorts *within* the embed rather than the
  /// top-level rows. That workaround is gone rather than generalised.
  ///
  /// Two things the server does here that the client structurally cannot:
  ///
  ///  * **Opposite sort directions in one result.** Upcoming reads best
  ///    soonest-first and past reads best most-recent-first, which is not one
  ///    `order` clause.
  ///  * **One clock.** `is_upcoming` comes from the same `now()` that produced
  ///    the ordering. Splitting on `DateTime.now()` here would let a party
  ///    starting inside the round trip be fetched as upcoming and rendered as
  ///    past, and would put a device with a skewed clock permanently at odds
  ///    with the server.
  ///
  /// Takes no user id, and [get_my_hosted_parties] has no parameter for one:
  /// it is only ever answerable about `auth.uid()`. For somebody else's
  /// profile the question is a different and narrower one — see
  /// [fetchHostedParties] with `publicOnly`.
  Future<HostedParties> fetchMyHostedParties() async {
    if (currentUserId == null) return HostedParties.empty;

    final rows = await _client.rpc('get_my_hosted_parties');

    return HostedParties.fromRows(
      (rows as List).cast<Map<String, dynamic>>(),
    );
  }

  /// Trades cover paths for short-lived signed URLs, keyed by **party id**.
  ///
  /// `party-covers` is a private bucket, so unlike an avatar this cannot be a
  /// public URL. Unlike `story-media` it also needs no edge function: that
  /// bucket ships zero policies and is reachable only through a service-role
  /// signature, whereas `party-covers` carries a real SELECT policy tied to
  /// party visibility (`20260812124217`). Storage authorizes this call with the
  /// caller's own JWT against that policy, so a party the viewer may not see
  /// cannot be signed — RLS decides, exactly as it does for the row itself.
  ///
  /// Keyed by party id rather than by path so the caller never has to hold a
  /// storage key to look up its own image, and so a party with no cover is
  /// simply absent from the map rather than mapping to null.
  ///
  /// One request for the whole list. Failures are dropped rather than thrown:
  /// a cover that will not sign is a card that draws its placeholder, which is
  /// the same thing the card does for a party that never had one.
  Future<Map<String, String>> signedCoverUrls(
    List<PartySummary> parties, {
    int expiresIn = 3600,
  }) async {
    final withCovers = parties.where((p) => p.hasCover).toList();
    if (withCovers.isEmpty) return {};

    final byPath = {for (final p in withCovers) p.coverPath!: p.id};

    final results = await _client.storage
        .from('party-covers')
        .createSignedUrlsResult(byPath.keys.toList(), expiresIn);

    return {
      for (final result in results)
        if (result is SignedUrlSuccess && byPath.containsKey(result.path))
          byPath[result.path]!: result.signedUrl,
    };
  }

  /// The map query: published, unfinished parties around [lon]/[lat], already
  /// tier-filtered by [radiusMeters] and already ordered sponsored-then-nearest
  /// by the server.
  ///
  /// This lived inside `MapScreen` as a bare `Supabase.instance.client.rpc`
  /// until now, which is the reason the map was the one screen with no widget
  /// test: a widget holding its own client cannot be driven under
  /// `flutter test`, where there is no initialized Supabase to hold.
  ///
  /// [limit] must stay in step with the RPC's own default (200) and its hard
  /// ceiling (500) — the server clamps, so a larger number here silently
  /// becomes 500 rather than erroring. Callers that want to tell "this is
  /// everything" from "the viewport is saturated" compare the returned length
  /// against the limit they asked for; the RPC has no total to give, and
  /// counting one would cost a second pass over the same expensive scan.
  ///
  /// Rows missing a coordinate are dropped rather than defaulted. `lat`/`lon`
  /// come from `st_y`/`st_x` on a non-null geography column so this should not
  /// happen, but a pin at (0, 0) in the Gulf of Guinea is a worse outcome than
  /// a pin that is absent.
  Future<List<MapPartyPin>> fetchPartiesNearUser({
    required double lon,
    required double lat,
    required double radiusMeters,
    int limit = 200,
  }) async {
    final rows = await _client.rpc('get_parties_near_user', params: {
      'map_center_lon': lon,
      'map_center_lat': lat,
      'radius_meters': radiusMeters,
      'p_limit': limit,
    });

    final pins = <MapPartyPin>[];
    for (var i = 0; i < (rows as List).length; i++) {
      final row = rows[i] as Map<String, dynamic>;
      if (row['lat'] == null || row['lon'] == null) continue;
      pins.add(MapPartyPin.fromRpcRow(row, fallbackId: 'pin_$i'));
    }
    return pins;
  }

  /// Text search over party titles and areas, with no spatial bound at all —
  /// unlike [fetchPartiesNearUser], this deliberately ignores where the map is
  /// looking. Typing a name should find the party wherever it is.
  ///
  /// Returns [MapPartyPin]s because the RPC emits `lat`/`lon` for exactly that
  /// reason: a search hit converts into the same model the map uses, so tapping
  /// one opens the same sheet, with the same report action and the same live
  /// count. A separate search-result type would have been a second thing to
  /// keep in step with the payload for no gain.
  ///
  /// **The upcoming/past split comes from the server and is not recomputed
  /// here.** `is_past` is `public.party_is_past()`, which is the single
  /// definition of "this party is over" (see
  /// `docs/phase-14-text-search.md` §4). Deciding it again in Dart would make a
  /// second one, and the two would disagree about a party with no stated end —
  /// which is the whole problem gotcha 21 describes.
  ///
  /// Sends the query raw. Normalization — lowercasing, stripping accents,
  /// transliterating Greek so `taratsa` finds `Ταράτσα` — happens server-side
  /// in `search_normalize()`, because the stored tokens went through the same
  /// function and a second copy of that mapping in Dart would diverge from it.
  ///
  /// Callers are expected to hold back short queries: see
  /// [SearchScreen.minQueryLength]. A one- or two-character prefix matches a
  /// large fraction of the corpus and is slow for a result nobody wants; the
  /// RPC is deliberately uncapped rather than silently returning a subset, so
  /// the restraint lives here rather than in the database.
  Future<PartySearchResults> searchParties(String query, {int limit = 20}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const PartySearchResults(upcoming: [], past: []);

    final rows = await _client.rpc(
      'search_parties',
      params: {'p_query': trimmed, 'p_limit': limit},
    );

    final upcoming = <MapPartyPin>[];
    final past = <MapPartyPin>[];
    for (var i = 0; i < (rows as List).length; i++) {
      final row = rows[i] as Map<String, dynamic>;
      if (row['lat'] == null || row['lon'] == null) continue;
      final pin = MapPartyPin.fromRpcRow(row, fallbackId: 'hit_$i');
      ((row['is_past'] as bool?) ?? false ? past : upcoming).add(pin);
    }
    return PartySearchResults(upcoming: upcoming, past: past);
  }
}

/// Party search results, already split the way they are rendered.
///
/// Two lists rather than one list plus a flag, because every caller wants the
/// grouping and none of them should be the place that decides it.
class PartySearchResults {
  const PartySearchResults({required this.upcoming, required this.past});

  final List<MapPartyPin> upcoming;
  final List<MapPartyPin> past;

  bool get isEmpty => upcoming.isEmpty && past.isEmpty;
  int get length => upcoming.length + past.length;
}
