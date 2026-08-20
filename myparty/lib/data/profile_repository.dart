import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profile.dart';
import '../models/profile_privacy.dart';
import '../models/profile_stats.dart';

/// Every widget-level Supabase call for the profile screen's own data — the two
/// privacy columns and the three counters — goes through here. Screens never
/// call `Supabase.instance.client` directly. Mirrors [SocialRepository] and
/// [DeviceRepository].
///
/// Separate from [SocialRepository] (which owns the follow graph and blocks) and
/// from [DeviceRepository] (which owns `user_devices` and the notification
/// preference columns) because this is a third surface: settings the user
/// chooses about *other people's access to them*, plus read-only aggregates.
///
/// Nothing here enforces a privacy rule. `invite_policy` is enforced by the
/// `invitations` INSERT policy and `map_visibility` by `get_parties_near_user`,
/// so these methods only read and write the user's stated preference — the
/// server would apply it whether or not this file existed.
class ProfileRepository {
  ProfileRepository({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  /// Resolved lazily rather than in the constructor, for the same reason
  /// [DeviceRepository] does it: a test double subclasses this and overrides
  /// every method, and constructing a real client needs an initialized
  /// Supabase, which does not exist under `flutter test`.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  String? get currentUserId => _client.auth.currentUser?.id;

  /// The identity row behind the profile header: who this is and their two
  /// follow counters.
  ///
  /// [userId] null means **the signed-in user**, resolved from the session here
  /// rather than accepted from the caller. That asymmetry is the point: a screen
  /// may say "whoever I am" or it may name someone, and it must not be able to
  /// say "I am this uuid". Nothing downstream treats the argument as an
  /// identity claim either — the row comes back through the `profiles` SELECT
  /// policy exactly like any other user's would.
  ///
  /// Returns null for both "no such row" and "the policy filtered it" (the
  /// caller has blocked them, or they have blocked the caller). Deliberately
  /// not distinguished: the two are indistinguishable from here by design, and
  /// a caller that could tell them apart would be a block-detection oracle.
  ///
  /// Selects six columns and no more. `credibility_score` is omitted for the
  /// reason in [Profile]; `deleted_at` is omitted because this is not a
  /// discovery surface — you reached a specific profile, and a tombstone should
  /// render as its scrubbed handle rather than vanish (see the inner-join
  /// argument in [SocialRepository.searchProfiles]).
  ///
  /// `bio` and `avatar_path` need no extra filtering here, and asking for them
  /// changes nothing about who gets a row. They ride the same block-filtered
  /// `profiles` SELECT policy as `username` does, because RLS gates rows rather
  /// than columns — a blocked viewer gets no row at all, which is why the null
  /// return above already covers them. On a tombstone both come back null:
  /// `complete_account_erasure` scrubs them alongside the handle.
  Future<Profile?> fetchProfile({String? userId}) async {
    final id = userId ?? currentUserId;
    if (id == null) return null;

    final row = await _client
        .from('profiles')
        .select('id, username, bio, avatar_path, follower_count, following_count')
        .eq('id', id)
        .maybeSingle();

    if (row == null) return null;
    return Profile.fromRow(row);
  }

  /// Reads the current user's own privacy tiers.
  ///
  /// Only ever the current user's: the values are a preference, and there is no
  /// screen that shows you someone else's. (The `profiles` SELECT policy would
  /// happily return another user's row, which is exactly why the caller should
  /// not be able to ask for one here by accident.)
  Future<ProfilePrivacy?> fetchPrivacy() async {
    final userId = currentUserId;
    if (userId == null) return null;

    final row = await _client
        .from('profiles')
        .select('map_visibility, invite_policy')
        .eq('id', userId)
        .maybeSingle();

    if (row == null) return null;
    return ProfilePrivacy.fromRow(row);
  }

  /// Writes either or both tiers.
  ///
  /// A plain PATCH: `profiles` already carries a table-wide UPDATE grant and an
  /// owner-only policy, and both columns are `not null` enums, so a bad value is
  /// a 22P02 from the database rather than a silently stored string. The
  /// `protect_credibility_score` trigger deliberately does not freeze these —
  /// it exists for system-maintained columns, and freezing a preference the user
  /// is supposed to set would make the toggle do nothing.
  Future<void> updatePrivacy({MapVisibility? mapVisibility, InvitePolicy? invitePolicy}) async {
    final userId = currentUserId;
    if (userId == null) return;

    final patch = <String, dynamic>{
      'map_visibility': ?mapVisibility?.wire,
      'invite_policy': ?invitePolicy?.wire,
    };

    if (patch.isEmpty) return;
    await _client.from('profiles').update(patch).eq('id', userId);
  }

  /// The three profile counters, for [userId] or the current user.
  ///
  /// Returns [ProfileStats.empty] rather than null when signed out, because the
  /// tiles are always drawn and "no stats" and "zero stats" render identically.
  /// The RPC itself always returns exactly one row, even for a user id that does
  /// not exist.
  ///
  /// Remember that `parties_attended` comes back as 0 for anyone but the owner —
  /// see [ProfileStats]. Callers must not present that as a real count.
  Future<ProfileStats> fetchStats({String? userId}) async {
    final id = userId ?? currentUserId;
    if (id == null) return ProfileStats.empty;

    final rows = await _client.rpc('get_profile_stats', params: {'p_user_id': id});

    final list = rows as List;
    if (list.isEmpty) return ProfileStats.empty;
    return ProfileStats.fromRow(list.first as Map<String, dynamic>);
  }
}
