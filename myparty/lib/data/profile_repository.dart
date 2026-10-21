import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/gender.dart';
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

/// Why `complete_onboarding` or `change_username` refused a username.
enum UsernameRefusal {
  /// Fails `username_is_valid` (22023). The client's [UsernameConstraint]
  /// should have caught it first.
  invalid,

  /// The exact name the account already has (22023). Refused so a slip does
  /// not cost 30 days.
  unchanged,

  /// Held by another account or reserved after a rename (23505). One reason
  /// for both, on purpose: the server does not say which.
  taken,

  /// Changed less than 30 days ago (42501); [UsernameRefused.nextChangeAt]
  /// says when.
  cooldown,
}

/// A username write the server refused for a reason the user can act on.
/// Anything else (network, a 42501 that is not the cooldown) is rethrown as it
/// came.
class UsernameRefused implements Exception {
  const UsernameRefused(this.reason, {this.nextChangeAt});

  final UsernameRefusal reason;

  /// Only for [UsernameRefusal.cooldown]: when a change is next allowed, from
  /// the error's DETAIL. Null if it could not be read.
  final DateTime? nextChangeAt;

  /// Turns the PostgREST error into a refusal, or null when it is not one.
  static UsernameRefused? fromPostgrest(PostgrestException error) {
    return switch ((error.code, error.message)) {
      ('23505', _) => const UsernameRefused(UsernameRefusal.taken),
      ('22023', 'invalid username') => const UsernameRefused(UsernameRefusal.invalid),
      ('22023', 'username unchanged') => const UsernameRefused(UsernameRefusal.unchanged),
      ('42501', 'username change cooldown') => UsernameRefused(
          UsernameRefusal.cooldown,
          nextChangeAt: DateTime.tryParse('${error.details ?? ''}')?.toLocal(),
        ),
      _ => null,
    };
  }

  @override
  String toString() => 'UsernameRefused($reason, nextChangeAt: $nextChangeAt)';
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
  /// A plain PATCH, like the privacy tiers: `bio` is in the `profiles` UPDATE
  /// column grant (20261021094726) with an owner-only row policy, and this is
  /// the user's own text about themselves — the same shape as
  /// `map_visibility`. The username is not in that grant; see
  /// [changeUsername].
  ///
  /// Validation is [BioConstraint]'s job on the way in, and the CHECK
  /// constraint's job for real. A value that gets past the first arrives here
  /// and is refused by the second as a 23514 rather than being stored.
  Future<void> updateBio(String? bio) async {
    final userId = currentUserId;
    if (userId == null) return;

    await _client.from('profiles').update({'bio': bio}).eq('id', userId);
  }

  /// Whether [username] is free across ALL profiles. The RPC is security
  /// definer because the `profiles` SELECT policy is block-filtered, so a plain
  /// select would answer from the caller's filtered view (gotcha 1).
  Future<bool> isUsernameAvailable(String username) async {
    return await _client.rpc(
      'check_username_available',
      params: {'p_username': username},
    ) as bool;
  }

  /// Onboarding's last step, through `complete_onboarding`: the username, the
  /// first and last name, and `onboarding_completed_at` (the server's clock),
  /// in one transaction. The stamp is what routes the user past
  /// [UsernameSetupScreen] from then on.
  ///
  /// The server is the real arbiter of the name; [isUsernameAvailable] only
  /// gives a friendlier error for the common case. Throws [UsernameRefused]
  /// for a taken or invalid name. Choosing the first name does not start the
  /// 30-day cooldown, so it can be fixed once straight away.
  Future<void> completeOnboarding({
    required String username,
    required String firstName,
    required String lastName,
  }) async {
    if (currentUserId == null) throw StateError('No signed-in user to onboard');

    try {
      await _client.rpc('complete_onboarding', params: {
        'p_username': username,
        'p_first_name': firstName,
        'p_last_name': lastName,
      });
    } on PostgrestException catch (error) {
      throw UsernameRefused.fromPostgrest(error) ?? error;
    }
  }

  /// Changes the signed-in user's username through `change_username`, and
  /// returns when the next change is allowed.
  ///
  /// The server enforces everything: the format rule, the 30-day cooldown
  /// (which is also the rate limit) and the 14-day reservation of the name
  /// given up. Throws [UsernameRefused] for each of those. No `DataChange`:
  /// nothing of the viewer's own already renders their handle except the
  /// profile, which reloads (backlog 1.20).
  Future<DateTime> changeUsername(String username) async {
    try {
      final next = await _client.rpc('change_username', params: {'p_username': username});
      return DateTime.parse(next as String).toLocal();
    } on PostgrestException catch (error) {
      throw UsernameRefused.fromPostgrest(error) ?? error;
    }
  }

  /// When the signed-in user may next change their username, or null when
  /// they may now. The 30 days lives on the server only, so the screen asks
  /// rather than adding it to anything.
  Future<DateTime?> fetchUsernameNextChangeAt() async {
    if (currentUserId == null) return null;
    final next = await _client.rpc('username_next_change_at');
    return next == null ? null : DateTime.parse(next as String).toLocal();
  }

  /// The signed-in user's first and last name, from `user_names` under its
  /// owner-only policy. Null when there is no row (an account onboarded
  /// before names were asked for) or when signed out. Nobody else can read
  /// them.
  Future<({String firstName, String lastName})?> fetchMyNames() async {
    final userId = currentUserId;
    if (userId == null) return null;

    final row = await _client
        .from('user_names')
        .select('first_name, last_name')
        .eq('user_id', userId)
        .maybeSingle();
    if (row == null) return null;
    return (firstName: row['first_name'] as String, lastName: row['last_name'] as String);
  }

  /// Sets both names through `set_my_names`, never `.upsert()`: the table has
  /// no client write grant. The server trims and refuses an empty or
  /// over-long name with 22023.
  Future<void> setNames({required String firstName, required String lastName}) async {
    await _client.rpc('set_my_names', params: {
      'p_first_name': firstName,
      'p_last_name': lastName,
    });
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
  /// upload.
  ///
  /// The hourly `avatar-sweep` (20261021094728) collects whatever (3) and the
  /// orphan branch of (2) leave behind, so "bounded" now also means "temporary". Passed in rather than re-read here so this method makes exactly
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

  /// Removes the avatar: nulls `profiles.avatar_path`, then deletes the
  /// object [previousPath] names.
  ///
  /// The same order as [replaceAvatar] and for the same reason: the column is
  /// the commit, and until it is written the old photo is still the live one.
  /// If the column write fails this throws and nothing has changed. If the
  /// delete fails it does NOT throw — the photo is gone from the profile,
  /// which is what was asked — and returns false; the object is unreferenced
  /// from that moment, so the hourly `avatar-sweep` deletes it through the
  /// Storage API within the hour. The bucket is public, so until then a URL
  /// someone already holds still loads.
  Future<bool> removeAvatar({required String previousPath}) async {
    await writeAvatarPath(null);
    return removeAvatarObject(previousPath);
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
  // test doubles should call them; [replaceAvatar] and [removeAvatar] are the
  // only supported ways to change an avatar, because they get the order right.

  /// PUTs the bytes. Direct client write, owner-scoped by the bucket policy.
  Future<void> uploadAvatarObject(String path, Uint8List bytes, String contentType) async {
    await _client.storage.from('avatars').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType),
        );
  }

  /// The commit: points the column at [path], or clears it when null. Throws
  /// on refusal — [replaceAvatar] turns that into an [AvatarCommitFailure]
  /// after cleaning up.
  Future<void> writeAvatarPath(String? path) async {
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
        .select('map_visibility, invite_policy, dm_policy')
        .eq('id', userId)
        .maybeSingle();

    if (row == null) return null;
    return ProfilePrivacy.fromRow(row);
  }

  /// Writes any of the three tiers.
  ///
  /// A plain PATCH: all three columns are in the `profiles` UPDATE column
  /// grant under an owner-only policy, and all three columns are `not null` enums, so a bad value is
  /// a 22P02 from the database rather than a silently stored string. The
  /// `protect_credibility_score` trigger deliberately does not freeze these —
  /// it exists for system-maintained columns, and freezing a preference the user
  /// is supposed to set would make the toggle do nothing.
  Future<void> updatePrivacy({
    MapVisibility? mapVisibility,
    InvitePolicy? invitePolicy,
    DmPolicy? dmPolicy,
  }) async {
    final userId = currentUserId;
    if (userId == null) return;

    final patch = <String, dynamic>{
      'map_visibility': ?mapVisibility?.wire,
      'invite_policy': ?invitePolicy?.wire,
      'dm_policy': ?dmPolicy?.wire,
    };

    if (patch.isEmpty) return;
    await _client.from('profiles').update(patch).eq('id', userId);
  }

  /// The current user's own gender answer; [Gender.preferNotToSay] when there
  /// is no row, which is also what choosing it stores. Null only when signed
  /// out.
  ///
  /// Read from `user_genders` under its owner-only policy, never from the auth
  /// metadata: the sign-up copy there is stripped (20261019193257) and was
  /// never updated by Settings anyway.
  Future<Gender?> fetchMyGender() async {
    final userId = currentUserId;
    if (userId == null) return null;

    final row = await _client.from('user_genders').select('gender').eq('user_id', userId).maybeSingle();
    return Gender.fromWire(row?['gender'] as String?);
  }

  /// Sets or clears (prefer not to say) the current user's answer.
  ///
  /// Through `set_my_gender`, never `.upsert()`: the table has no client write
  /// grant at all. No `DataChange`: no other screen shows your own answer, and
  /// the host's dashboard deliberately hears nothing about it.
  Future<void> setGender(Gender gender) async {
    await _client.rpc('set_my_gender', params: {'p_gender': gender.wire});
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
