import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profile.dart';

/// Every widget-level Supabase call for the follow graph and blocks goes
/// through here — screens never call `Supabase.instance.client` directly.
/// Mirrors [PartyRepository].
///
/// None of these methods reimplement block filtering: `is_blocked` is baked
/// into the RLS policies on `profiles`, `follows` and `blocks`, so a blocked
/// user simply is not in any result set. Filtering again client-side would
/// duplicate the rule and drift from it.
class SocialRepository {
  SocialRepository({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  /// Resolved lazily rather than in the constructor so a test double can
  /// subclass this and override every method without `Supabase.instance`
  /// ever being touched — it is unset outside the app, and constructing a
  /// real client just to throw it away starts a realtime heartbeat timer
  /// that `pumpAndSettle` then blocks on.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  String? get _uid => _client.auth.currentUser?.id;

  /// People the current user follows — the host wizard's invite list.
  ///
  /// Bounded rather than keyset-paginated, like [PartyRepository.fetchMyRsvps]:
  /// this feeds a picker, not an infinite scroll. The composite index from
  /// 20260814094943 is `(follower_id, created_at desc, followee_id desc)`, so
  /// when this does need paging the keyset is `(created_at, followee_id)`.
  Future<List<Profile>> fetchFollowing({String? userId}) async {
    final id = userId ?? _uid;
    if (id == null) return [];

    final rows = await _client
        .from('follows')
        .select('profiles!follows_followee_id_fkey(id, username, follower_count, following_count)')
        .eq('follower_id', id)
        .order('created_at', ascending: false)
        .limit(200);

    return _unwrapJoined(rows, 'profiles');
  }

  /// People who follow [userId] (defaults to the current user).
  Future<List<Profile>> fetchFollowers({String? userId}) async {
    final id = userId ?? _uid;
    if (id == null) return [];

    final rows = await _client
        .from('follows')
        .select('profiles!follows_follower_id_fkey(id, username, follower_count, following_count)')
        .eq('followee_id', id)
        .order('created_at', ascending: false)
        .limit(200);

    return _unwrapJoined(rows, 'profiles');
  }

  Future<bool> isFollowing(String targetUserId) async {
    final id = _uid;
    if (id == null) return false;

    final row = await _client
        .from('follows')
        .select('follower_id')
        .eq('follower_id', id)
        .eq('followee_id', targetUserId)
        .maybeSingle();

    return row != null;
  }

  /// Throws if a block exists in either direction — the `follows` INSERT
  /// policy rejects it, which is what makes "cannot follow again until
  /// unblock" a server-side rule rather than a UI one.
  Future<void> follow(String targetUserId) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    await _client.from('follows').insert({
      'follower_id': id,
      'followee_id': targetUserId,
    });
  }

  Future<void> unfollow(String targetUserId) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    await _client
        .from('follows')
        .delete()
        .eq('follower_id', id)
        .eq('followee_id', targetUserId);
  }

  /// Username search, server-side through the `search_profiles` RPC.
  ///
  /// **This is PREFIX search, not substring.** It used to be
  /// `.ilike('username', '%$query%')`, which matched mid-word; typing `ikos`
  /// no longer finds `nikos_p`. That is a deliberate narrowing and it is a
  /// regression in reach, not just a new feature with limits — see
  /// `docs/phase-14-text-search.md`.
  ///
  /// What it buys: `ilike` is not leakproof, so it can never be evaluated
  /// ahead of the `profiles` row policy and can never reach an index. It
  /// seq-scanned the whole table and called `is_blocked` on every row —
  /// measured at 84ms per keystroke against 20k profiles, growing linearly
  /// with the user base. The prefix range is leakproof, sorts ahead of the
  /// policy, and reaches a `text_pattern_ops` index: 1.16ms.
  ///
  /// Why it has to be an RPC rather than a PostgREST filter, and why no
  /// normalization happens here: the query has to be folded to the same search
  /// key as the stored column (lowercase, accents stripped, Greek
  /// transliterated so `taratsa` finds `Ταράτσα`), and PostgREST cannot emit
  /// the `~>=~` operator the index needs — its `.gte()` is `>=`, which is a
  /// different operator class and silently does not use the index. Doing
  /// either half here would mean a second copy of the transliteration table in
  /// Dart, and two copies of that will diverge.
  ///
  /// Blocked users are absent because the `profiles` SELECT policy filters
  /// them; the RPC is `SECURITY INVOKER` precisely so that stays true.
  ///
  /// The `deleted_at` filter moved INTO the RPC and is now enforcement rather
  /// than the UX-only filter it was when this method spelled it out itself. It
  /// cannot go in the SELECT policy — `get_feed`, `get_messages` and four other
  /// RPCs reach the author through an inner join on `profiles`, so a profile
  /// made invisible by policy drops the message out of the thread entirely.
  Future<List<Profile>> searchProfiles(String query, {int limit = 30}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final rows = await _client.rpc(
      'search_profiles',
      params: {'p_query': trimmed, 'p_limit': limit},
    );

    return (rows as List)
        .map((row) => Profile.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  /// Blocking also deletes the follow edges in both directions, server-side
  /// (the `blocks_purge_follows` trigger). Callers should refresh any follow
  /// state they are holding rather than assuming it survived.
  Future<void> block(String targetUserId) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    await _client.from('blocks').insert({
      'blocker_id': id,
      'blocked_id': targetUserId,
    });
  }

  Future<void> unblock(String targetUserId) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    await _client
        .from('blocks')
        .delete()
        .eq('blocker_id', id)
        .eq('blocked_id', targetUserId);
  }

  /// Only ever returns blocks the current user created — the `blocks` SELECT
  /// policy is `blocker_id = auth.uid()`, so there is no way to ask who
  /// blocked you.
  Future<List<Profile>> fetchBlocked() async {
    final id = _uid;
    if (id == null) return [];

    final rows = await _client
        .from('blocks')
        .select('profiles!blocks_blocked_id_fkey(id, username, follower_count, following_count)')
        .eq('blocker_id', id)
        .order('created_at', ascending: false)
        .limit(200);

    return _unwrapJoined(rows, 'profiles');
  }

  List<Profile> _unwrapJoined(dynamic rows, String key) {
    return (rows as List)
        .map((row) => (row as Map<String, dynamic>)[key])
        .whereType<Map<String, dynamic>>()
        .map(Profile.fromRow)
        .toList();
  }
}
