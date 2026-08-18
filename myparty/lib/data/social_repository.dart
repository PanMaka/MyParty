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

  /// Username search. Blocked users are absent because the `profiles` SELECT
  /// policy filters them, not because of anything done here.
  Future<List<Profile>> searchProfiles(String query, {int limit = 30}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final rows = await _client
        .from('profiles')
        .select('id, username, follower_count, following_count')
        .ilike('username', '%$trimmed%')
        .neq('id', _uid ?? '00000000-0000-0000-0000-000000000000')
        .limit(limit);

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
