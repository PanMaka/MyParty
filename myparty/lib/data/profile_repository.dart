import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/profile.dart';
import '../models/profile_privacy.dart';
import '../models/profile_stats.dart';

/// The bytes landed in the bucket but `profiles.avatar_path` could not be
/// written, so nothing about the profile changed.
///
/// A named type rather than a rethrown PostgrestException because the two
/// outcomes underneath it are genuinely different to the user, and only this
/// layer knows which one happened. [orphanedPath] is null in the ordinary case
/// — the upload was rolled back and the bucket is exactly as it was. It is
/// non-null only when the cleanup delete ALSO failed, which is the one state
/// where a file is left behind with nothing pointing at it.
class AvatarCommitFailure implements Exception {
  const AvatarCommitFailure({required this.cause, this.orphanedPath});

  /// Whatever the column write threw. Kept rather than flattened to a string:
  /// a 42501 here would mean the row policy, which is a different bug from a
  /// dropped connection, and the caller should be able to tell.
  final Object cause;

  /// The object left unreferenced in the bucket, or null when the rollback
  /// succeeded and there is nothing to leak.
  final String? orphanedPath;

  bool get leftAnOrphan => orphanedPath != null;

  @override
  String toString() =>
      'AvatarCommitFailure(cause: $cause, orphanedPath: $orphanedPath)';
}

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

  /// Keys new avatar objects. A fresh one per upload — see [replaceAvatar].
  final _uuid = const Uuid();

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

  /// A loadable URL for a [Profile.avatarPath], or null when there is no avatar.
  ///
  /// Asks Storage for the URL rather than interpolating
  /// `/storage/v1/object/public/avatars/<path>` at the call site. `avatars` is
  /// the one bucket created with `public => true` (`20260812124217`), so today
  /// the SDK hands back an unsigned URL and this cannot fail — but public-read
  /// is a property of the BUCKET, not of the profile screen. The day that
  /// changes, the correct URL becomes a signed one with a lifetime, and every
  /// hand-built path keeps compiling while quietly returning 403s from a widget
  /// that never knew it was making a policy claim. Same argument that made the
  /// column store a key instead of a URL (`20260820095801` §2): the row holds
  /// the key, one place decides what to do with it.
  ///
  /// Synchronous, because a public URL is pure string construction inside the
  /// SDK. A signed one would make this a `Future` — which is precisely the kind
  /// of change that should be impossible to miss at the call site rather than
  /// absorbed silently.
  ///
  /// Takes the nullable path rather than a [Profile] so the "no avatar" case
  /// and the "no profile loaded yet" case collapse into one null here instead
  /// of into two branches in the widget.
  String? avatarUrl(String? path) {
    if (path == null) return null;
    return _client.storage.from('avatars').getPublicUrl(path);
  }

  /// Writes the user's own bio, where **null clears it**.
  ///
  /// Note the contrast with [updatePrivacy] directly below, which uses a
  /// null-aware element to OMIT absent keys from the patch. This one must do
  /// the opposite: `{'bio': null}` has to reach PostgREST as a JSON null so the
  /// column is set to null, because null is how "no bio" is spelled
  /// (`profiles_bio_one_short_line` rejects the empty string precisely so that
  /// it is the only spelling). Omitting the key would silently make clearing a
  /// bio a no-op — the failure would be invisible, and it would look exactly
  /// like the code above it. Do not unify them.
  ///
  /// A plain PATCH, like the privacy tiers: `profiles` carries a table-wide
  /// UPDATE grant with an owner-only row policy, and this is the user's own
  /// text about themselves — the same shape as `map_visibility`, and
  /// deliberately not covered by `protect_credibility_score`, which is for
  /// system-maintained columns.
  ///
  /// Validation is [BioConstraint]'s job on the way in, and the CHECK
  /// constraint's job for real. A value that gets past the first arrives here
  /// and is refused by the second as a 23514 rather than being stored.
  Future<void> updateBio(String? bio) async {
    final userId = currentUserId;
    if (userId == null) return;

    await _client.from('profiles').update({'bio': bio}).eq('id', userId);
  }

  /// Uploads a new avatar and points `profiles.avatar_path` at it, removing the
  /// object it replaces.
  ///
  /// Direct client write, unlike the `story-media` handshake, and that is not
  /// an inconsistency: `avatars` is the one public bucket, and
  /// `20260812124217` gives it owner-scoped INSERT/UPDATE/DELETE policies keyed
  /// on `(storage.foldername(name))[1]`. The signed-URL rule in CLAUDE.md #7 is
  /// about visibility-gated buckets, where the server has to decide who may
  /// read; here it has already decided that everyone may.
  ///
  /// ---- The order, which is the whole of this method ----
  ///
  /// Upload, then commit the column, then delete the old object. Every other
  /// ordering breaks something worse:
  ///
  ///  * **Column first** would point `avatar_path` at an object that does not
  ///    exist yet, so a failed upload leaves the profile asserting a photo it
  ///    cannot produce. An orphaned object costs storage; a dangling path is a
  ///    profile that is wrong.
  ///  * **Deleting the old object first** would destroy the avatar the user
  ///    still has in exchange for one they might not get. Until the column
  ///    write commits, the old object is still the live one.
  ///
  /// A fresh uuid key each time rather than overwriting a fixed
  /// `{uid}/avatar.jpg` with `upsert: true`. Two reasons, and the first is not
  /// about correctness: the bucket is public, so its URLs are cacheable and an
  /// overwritten key serves the previous photo out of a CDN or an image cache
  /// for as long as it likes. The second is that `upsert` destroys the old
  /// bytes *before* the commit point, which is the ordering ruled out above.
  ///
  /// ---- The three ways this does not simply succeed ----
  ///
  ///  1. **Cancelled.** Returns null, having deleted what it uploaded. The
  ///     storage client has no cancellation token, so an in-flight PUT cannot
  ///     be aborted — "cancel" therefore means the bytes are uploaded and then
  ///     removed, not that they were never sent. [isCancelled] is re-asked at
  ///     the one moment that matters, after the upload and before the commit,
  ///     because past that point the change has happened and pretending
  ///     otherwise would be the lie. Callers must back it with a plain field
  ///     rather than `State.mounted`: the sequence deliberately outlives the
  ///     widget so the cleanup still runs when someone navigates away.
  ///  2. **The commit fails.** Throws [AvatarCommitFailure] after deleting the
  ///     uploaded object, so the bucket is left as it was found. If that delete
  ///     also fails, the exception says so through
  ///     [AvatarCommitFailure.orphanedPath] instead of swallowing it.
  ///  3. **The old object will not delete.** Does NOT throw. The user asked to
  ///     change their photo and their photo has changed; failing the operation
  ///     at that point would report a success as a failure. The leftover is
  ///     bounded — it is inside this user's own `{user_id}/` folder, which is
  ///     what `complete_account_erasure` deletes by prefix — so it is a cost,
  ///     not a leak.
  ///
  /// [previousPath] is the caller's current `avatar_path`, or null on a first
  /// upload. Passed in rather than re-read here so this method makes exactly
  /// two writes and one delete, and so a caller holding a stale profile cannot
  /// cause it to delete an object the column still points at.
  Future<String?> replaceAvatar({
    required Uint8List bytes,
    required String? previousPath,
    bool Function()? isCancelled,
    String contentType = 'image/jpeg',
    String extension = 'jpg',
  }) async {
    final userId = currentUserId;
    if (userId == null) throw StateError('Not signed in');

    // Satisfies `profiles_avatar_path_own_folder` by construction: the uuid
    // contributes no '..' and no '/', and the whole key is far under 512.
    final newPath = '$userId/${_uuid.v4()}.$extension';

    await uploadAvatarObject(newPath, bytes, contentType);

    // (1) The last honest moment to cancel. After the write below, the profile
    // has changed and "cancelled" would not be true.
    if (isCancelled?.call() ?? false) {
      await removeAvatarObject(newPath);
      return null;
    }

    // (2) The commit. Everything before this is reversible; nothing after is.
    try {
      await writeAvatarPath(newPath);
    } catch (error) {
      final removed = await removeAvatarObject(newPath);
      throw AvatarCommitFailure(cause: error, orphanedPath: removed ? null : newPath);
    }

    // (3) Only now is the old object unreferenced. The guard is defensive
    // rather than load-bearing — a uuid key cannot collide — but it states the
    // invariant that this line must never delete the live avatar.
    if (previousPath != null && previousPath != newPath) {
      await removeAvatarObject(previousPath);
    }

    return newPath;
  }

  // ---- The three primitives [replaceAvatar] sequences. ----
  //
  // Split out as one seam so the ORDER can be tested, which is the part of
  // this file worth protecting: a test double overrides these three, and the
  // real [replaceAvatar] runs its real sequence against them. Inlined, the
  // ordering would only be provable against a live Supabase project, which
  // means in practice it would not be provable at all — and every one of the
  // three failure paths is a claim about what happened to the bucket, not
  // about what the caller saw.
  //
  // Not private, for that reason alone. Nothing outside this class and its
  // test doubles should call them; [replaceAvatar] is the only supported way
  // to change an avatar, because it is the only one that gets the order right.

  /// PUTs the bytes. Direct client write, owner-scoped by the bucket policy.
  Future<void> uploadAvatarObject(String path, Uint8List bytes, String contentType) async {
    await _client.storage.from('avatars').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType),
        );
  }

  /// The commit: points the column at [path]. Throws on refusal — the caller
  /// turns that into an [AvatarCommitFailure] after cleaning up.
  Future<void> writeAvatarPath(String path) async {
    final userId = currentUserId;
    if (userId == null) throw StateError('Not signed in');

    await _client.from('profiles').update({'avatar_path': path}).eq('id', userId);
  }

  /// Best-effort delete of one object in `avatars`. True if the bucket no
  /// longer holds it.
  ///
  /// Swallows the error and reports it as a bool, because every caller is
  /// already in a failure or a cleanup path where throwing would replace a
  /// precise story with a vaguer one. Storage's `remove` does not treat a
  /// missing key as an error, so "was not there" and "deleted" are both true —
  /// which is what the callers actually want to know.
  Future<bool> removeAvatarObject(String path) async {
    try {
      await _client.storage.from('avatars').remove([path]);
      return true;
    } catch (_) {
      return false;
    }
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
