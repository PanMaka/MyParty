import 'package:flutter/material.dart';

/// A real `public.profiles` row. Replaces the const `MpFriend` mock list —
/// there is no "friend" concept in the schema, only the asymmetric follow
/// graph, so this is just a user.
///
/// Deliberately carries no `credibilityScore`. The column still exists and is
/// still protected by `protect_credibility_score`, but Phase 8 decided that
/// nothing writes it and nothing shows it in v1 (see `docs/backend-plan.md`
/// 8.3) — so every value it could hold today is `0`. Fetching a column no
/// screen may render is not neutral: it is an affordance, and the obvious next
/// step for whoever finds it is to put the number on the profile. Add it back
/// in the same change that gives it a meaning.
class Profile {
  final String id;
  final String username;
  final int followerCount;
  final int followingCount;

  /// The single line rendered under the username and name, or null when the user has not
  /// written one. **Null is the only way this is absent** — `20260820095801`
  /// rejects the empty string and the whitespace-only string with a CHECK
  /// constraint, precisely so that no renderer downstream needs its own
  /// `.trim().isEmpty` guard to avoid drawing a blank line under the handle.
  ///
  /// Guaranteed by the same constraint to be at most 160 characters and to
  /// contain no newline, so it can be handed straight to a `Text` widget. Do
  /// not substitute a placeholder sentence when it is null: a bio is the user's
  /// own words, and a generated one presented in that slot reads as theirs.
  final String? bio;

  /// Path into the public `avatars` bucket (`{user_id}/…`), never a URL, and
  /// null when the user has no avatar. The column stores a key because the
  /// bucket is public-read here and private elsewhere — turning the key into
  /// something loadable is the caller's decision, not the row's.
  ///
  /// Null means "no avatar" and nothing else. [placeholderColors] is the honest
  /// fallback; it is a gradient that visibly is not a photograph, rather than a
  /// stock face that would read as one.
  final String? avatarPath;

  /// From the `user_names` embed, both or neither. Null when the user has no
  /// name, has not yet seen the Phase 49 notice (the policy keeps it owner-only
  /// until then), is pending deletion or erased, or is block-paired with the
  /// viewer. The header draws nothing for null: no gap, no placeholder.
  final String? firstName;
  final String? lastName;

  const Profile({
    required this.id,
    required this.username,
    required this.followerCount,
    required this.followingCount,
    this.bio,
    this.avatarPath,
    this.firstName,
    this.lastName,
  });

  factory Profile.fromRow(Map<String, dynamic> row) {
    return Profile(
      id: row['id'] as String,
      username: row['username'] as String,
      followerCount: (row['follower_count'] as int?) ?? 0,
      followingCount: (row['following_count'] as int?) ?? 0,
      // No `?? ''` and no `.trim()` on either: the database has already refused
      // every blank spelling, so collapsing null into '' here would throw away
      // the one distinction the constraint exists to preserve.
      bio: row['bio'] as String?,
      avatarPath: row['avatar_path'] as String?,
      firstName: _names(row)?['first_name'] as String?,
      lastName: _names(row)?['last_name'] as String?,
    );
  }

  /// The `user_names(first_name, last_name)` embed. One-to-one (its key is
  /// `user_id`), so PostgREST sends an object or null; a select without the
  /// embed has no key at all.
  static Map<String, dynamic>? _names(Map<String, dynamic> row) {
    final names = row['user_names'];
    return names is Map<String, dynamic> ? names : null;
  }

  /// This row with its follower count moved by [delta] — the profile screen's
  /// optimistic follow, applied the instant the button flips and undone the
  /// same way if the write is refused. Never below zero: a stale row and a
  /// rollback arriving together must not print "-1 followers".
  Profile withFollowerDelta(int delta) => Profile(
    id: id,
    username: username,
    followerCount: (followerCount + delta).clamp(0, 1 << 31),
    followingCount: followingCount,
    bio: bio,
    avatarPath: avatarPath,
    firstName: firstName,
    lastName: lastName,
  );

  /// True only when there is a real key to load. Guards the image widget, the
  /// same way [PartySummary.hasCapacity] guards the progress bar — an
  /// `Image.network` on an empty string is a broken-image icon, which is a
  /// worse "no avatar" than no avatar.
  bool get hasAvatar => avatarPath != null;

  /// True only when the user wrote a line. Named rather than left to callers
  /// checking `bio != null`, so the "no fabricated value" rule has one place to
  /// live if the emptiness question ever gets more complicated.
  bool get hasBio => bio != null;

  /// "First Last", or null. The server stores both or neither, so one half
  /// alone is not a state worth rendering.
  String? get fullName {
    final first = firstName, last = lastName;
    return first == null || last == null ? null : '$first $last';
  }

  /// The avatar fallback, for the [hasAvatar] == false case. Derived from the
  /// uuid so a given user always gets the same pair and the list stops looking
  /// like it reshuffles on every rebuild — the const `MpFriend.colors` used to
  /// provide this by hand.
  ///
  /// No longer a stand-in for a column that does not exist: [avatarPath] exists
  /// now, and this is what gets drawn when it is null.
  List<Color> get placeholderColors {
    final hue = (id.hashCode.abs() % 360).toDouble();
    return [
      HSLColor.fromAHSL(1, hue, 0.32, 0.20).toColor(),
      HSLColor.fromAHSL(1, hue, 0.30, 0.13).toColor(),
    ];
  }
}

/// The client-side mirror of the `profiles_bio_one_short_line` CHECK
/// constraint (`20260820095801` §1).
///
/// This is a **convenience, not a boundary**. The constraint is the boundary:
/// it runs inside the transaction, it cannot be skipped by a definer function
/// that forgot about it, and it is what makes `Profile.bio` safe to hand
/// straight to a `Text` widget everywhere downstream. Everything here exists so
/// the user finds out before the round trip instead of after — delete it and
/// the database still refuses exactly the same values, with a worse error.
///
/// Which is also why it is written as a mirror of the four SQL conditions in
/// the same order rather than as "whatever the form needs". Any drift between
/// the two is a bug in this file by definition, and `profile_edit_test.dart`
/// asserts each condition separately for that reason.
class BioConstraint {
  BioConstraint._();

  /// `char_length(bio) <= 160`. See the migration for why 160 and not 280.
  static const maxCharacters = 160;

  /// The length the CHECK will measure.
  ///
  /// Postgres `char_length` counts **characters**; Dart's `String.length`
  /// counts UTF-16 code units. They agree across Greek and Latin and disagree
  /// outside the BMP — an emoji is 1 to `char_length` and 2 to `.length`. So
  /// `.length` would refuse bios the column accepts, and would do it only to
  /// people who use emoji, which is the same shape of bug as the byte-vs-char
  /// cap the migration rejected for Greek. `runes` is the exact mirror.
  static int length(String value) => value.runes.length;

  /// What a text field's contents become on the way to the column.
  ///
  /// The empty and whitespace-only cases collapse to **null**, because null is
  /// the one spelling of "no bio" the constraint permits and the whole reason
  /// `btrim(bio) <> ''` is in it — a form that round-tripped '' would produce a
  /// row that is neither "has a bio" nor "has none".
  ///
  /// Trimming the surviving value is this form's decision and not the
  /// constraint's: `btrim(bio) <> ''` only rejects a value that is *entirely*
  /// spaces, and the column would happily store `'  Κουκάκι  '`. Storing it
  /// trimmed is what makes the rendered line match what the user believes they
  /// typed. Note Dart's `trim()` is also broader than one-argument `btrim`,
  /// which strips ASCII spaces only — stricter than the constraint, which is
  /// the safe direction and deliberate.
  static String? normalize(String input) {
    final trimmed = input.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Null when [value] would satisfy the CHECK, otherwise the reason, in Greek,
  /// phrased for the person typing.
  ///
  /// Takes the **normalized** value — what will actually be sent — so that what
  /// is validated and what is stored cannot be two different strings.
  static String? validate(String? value) {
    // `bio is null` — the first branch of the CHECK, and a perfectly good bio.
    if (value == null) return null;

    // `btrim(bio) <> ''`. Unreachable through [normalize], which is the point:
    // it stays here so this function alone is a complete statement of the
    // constraint, rather than one that is only correct if called in order.
    if (value.trim().isEmpty) return 'Write something or leave it empty.';

    // `position(E'\n' in bio) = 0 and position(E'\r' in bio) = 0`.
    //
    // Rejected rather than silently stripped. The keyboard cannot produce a
    // newline in a single-line field, so the only way one arrives is a paste —
    // and quietly deleting part of what somebody pasted is a worse answer than
    // telling them the field is one line, which is the thing the column
    // actually enforces.
    if (value.contains('\n') || value.contains('\r')) {
      return 'Your bio is one line.';
    }

    // `char_length(bio) <= 160`.
    if (length(value) > maxCharacters) {
      return 'Up to $maxCharacters characters.';
    }

    return null;
  }
}

/// The client's mirror of `username_is_valid` (20261021094726), for the
/// keyboard rather than the decision: `complete_onboarding` and
/// `change_username` run the real one and refuse with 22023 whatever this says.
///
/// Applies to a name being CHOSEN. A name set before the rule existed stays
/// valid for its owner, which is why [validate] is never run on the stored
/// value except to tell its owner (the edit screen's notice).
class UsernameConstraint {
  UsernameConstraint._();

  static const minCharacters = 3;
  static const maxCharacters = 30;

  /// One sentence, shown wherever a username is typed.
  static const rules =
      '3-30 letters, numbers, _ or . (no dot at the start or end, and no two dots in a row).';

  static final _allowed = RegExp(r'^[A-Za-z0-9_.]+$');

  /// Null when [value] would pass `username_is_valid`, otherwise the reason.
  /// Takes the trimmed value, which is what is sent.
  static String? validate(String value) {
    if (value.length < minCharacters) return 'Username must be at least 3 characters';
    if (value.length > maxCharacters) return 'Up to $maxCharacters characters.';
    if (!_allowed.hasMatch(value)) return 'Use only letters, numbers, _ and .';
    if (value.startsWith('.') || value.endsWith('.')) {
      return "A username can't start or end with a dot.";
    }
    if (value.contains('..')) return "A username can't have two dots in a row.";
    // The tombstone prefix. Phrased as unavailable rather than explained: the
    // reason is a server detail, and "taken" is what it amounts to.
    if (value.toLowerCase().startsWith('deleted_')) return 'That username is not available.';
    return null;
  }

  static bool isValid(String value) => validate(value) == null;
}

/// Under the name fields in Edit profile and at onboarding (Phase 49). Says
/// what is true: the name shows on the profile, and search is by username
/// only (backlog 1.50). Not an anonymity promise in either direction.
const nameVisibilityNote =
    'Optional. Your name is shown on your profile. Others can find you by your username.';

/// The client's mirror of `person_name_is_valid` (20261021094725): trimmed,
/// 1-50 characters, no control characters, and nothing about alphabets.
class PersonNameConstraint {
  PersonNameConstraint._();

  static const maxCharacters = 50;

  /// Null when the trimmed [value] would be accepted, otherwise the reason.
  /// [label] names the field ("first name") in the empty case.
  static String? validate(String value, {required String label}) {
    if (value.isEmpty) return 'Please enter your $label.';
    // `char_length`, so runes rather than UTF-16 units (see BioConstraint).
    if (value.runes.length > maxCharacters) return 'Up to $maxCharacters characters.';
    if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(value)) return 'Use one line.';
    return null;
  }

  /// Names are optional since Phase 49, but both or neither (`set_my_names`
  /// refuses half a name). Takes trimmed values; returns each field's error.
  static ({String? first, String? last}) validatePair(String first, String last) {
    if (first.isEmpty && last.isEmpty) return (first: null, last: null);
    return (
      first: first.isEmpty ? 'Add your first name too, or leave both empty.' : validate(first, label: 'first name'),
      last: last.isEmpty ? 'Add your last name too, or leave both empty.' : validate(last, label: 'last name'),
    );
  }
}
