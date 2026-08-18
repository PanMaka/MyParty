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

  const Profile({
    required this.id,
    required this.username,
    required this.followerCount,
    required this.followingCount,
  });

  factory Profile.fromRow(Map<String, dynamic> row) {
    return Profile(
      id: row['id'] as String,
      username: row['username'] as String,
      followerCount: (row['follower_count'] as int?) ?? 0,
      followingCount: (row['following_count'] as int?) ?? 0,
    );
  }

  /// Stand-in for the avatar the `avatars` bucket will eventually serve.
  /// Derived from the uuid so a given user always gets the same pair and the
  /// list stops looking like it reshuffles on every rebuild — the const
  /// `MpFriend.colors` used to provide this by hand.
  List<Color> get placeholderColors {
    final hue = (id.hashCode.abs() % 360).toDouble();
    return [
      HSLColor.fromAHSL(1, hue, 0.32, 0.20).toColor(),
      HSLColor.fromAHSL(1, hue, 0.30, 0.13).toColor(),
    ];
  }
}
