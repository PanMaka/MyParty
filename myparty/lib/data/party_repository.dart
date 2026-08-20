import 'package:supabase_flutter/supabase_flutter.dart';

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
        .select('id, title, starts_at, is_private, going_count, interested_count, max_capacity')
        .eq('host_id', id)
        .eq('status', 'published');

    final scoped = publicOnly ? base.eq('is_private', false) : base;
    final windowed = upcoming ? scoped.gte('starts_at', nowIso) : scoped.lt('starts_at', nowIso);

    final rows = await windowed.order('starts_at', ascending: upcoming).limit(limit);

    return (rows as List)
        .map((row) => PartySummary.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  /// Past parties the current user actually went to — a `going` RSVP on a
  /// party that has already started.
  ///
  /// Current-user only, and that is a property of the data rather than a
  /// choice: the `rsvps` SELECT policy is `user_id = auth.uid() OR I host the
  /// party`, so asking this about anyone else returns their RSVPs on parties
  /// you host and nothing more — a number that would look like their history
  /// and be a fact about yours. Same reasoning that keeps
  /// `ProfileStats.partiesAttended` owner-only.
  ///
  /// Sorted in Dart, unusually for this file. PostgREST's `order` on an
  /// embedded resource sorts *within* the embed, not the top-level rows, so
  /// there is no way to ask the server for "my past parties, most recent
  /// first" through a join. The bound is generous and the strip shows three;
  /// when this needs real paging it becomes an RPC rather than a bigger limit.
  Future<List<PartySummary>> fetchAttendedParties({int limit = 50}) async {
    final userId = currentUserId;
    if (userId == null) return [];

    final nowIso = DateTime.now().toUtc().toIso8601String();

    final rows = await _client
        .from('rsvps')
        .select(
          'parties!inner(id, title, starts_at, is_private, going_count, interested_count, max_capacity)',
        )
        .eq('user_id', userId)
        .eq('status', 'going')
        .eq('parties.status', 'published')
        .lt('parties.starts_at', nowIso)
        .limit(limit);

    final parties = (rows as List)
        .map((row) => (row as Map<String, dynamic>)['parties'])
        .whereType<Map<String, dynamic>>()
        .map(PartySummary.fromRow)
        .toList();

    parties.sort((a, b) => b.startsAt.compareTo(a.startsAt));
    return parties;
  }
}
