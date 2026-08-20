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

  /// The single line rendered under `@username`, or null when the user has not
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

  const Profile({
    required this.id,
    required this.username,
    required this.followerCount,
    required this.followingCount,
    this.bio,
    this.avatarPath,
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
    );
  }

  /// True only when there is a real key to load. Guards the image widget, the
  /// same way [PartySummary.hasCapacity] guards the progress bar — an
  /// `Image.network` on an empty string is a broken-image icon, which is a
  /// worse "no avatar" than no avatar.
  bool get hasAvatar => avatarPath != null;

  /// True only when the user wrote a line. Named rather than left to callers
  /// checking `bio != null`, so the "no fabricated value" rule has one place to
  /// live if the emptiness question ever gets more complicated.
  bool get hasBio => bio != null;

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
