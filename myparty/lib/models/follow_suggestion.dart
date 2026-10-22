import 'package:flutter/material.dart';

import 'profile.dart';

/// Why `get_follow_suggestions` put someone on the list. One per account: the
/// server ranks each account into its best tier only.
enum SuggestionReason {
  /// Followed by people the viewer follows.
  mutuals('mutuals'),

  /// Follows the viewer, who does not follow back.
  followsYou('follows_you'),

  /// The fallback: a well-followed account with no connection to the viewer.
  popular('popular');

  const SuggestionReason(this.wire);

  final String wire;

  static SuggestionReason fromWire(String? value) =>
      SuggestionReason.values.firstWhere((r) => r.wire == value, orElse: () => SuggestionReason.popular);
}

/// Where the next page of suggestions starts: the last row drawn, echoed back.
///
/// The server's keyset is `(sort_tier, sort_rank, user_id)` ascending; the
/// client never computes either number, it only returns what it was given.
class SuggestionCursor {
  const SuggestionCursor({required this.tier, required this.rank, required this.userId});

  final int tier;
  final int rank;
  final String userId;
}

/// One row of `get_follow_suggestions`. Every field is one the viewer could
/// already read elsewhere (a profile, a follower list); the opt-out and the
/// onboarding state the server filtered on never reach the client.
class FollowSuggestion {
  const FollowSuggestion({
    required this.userId,
    required this.username,
    required this.reason,
    required this.followsYou,
    required this.mutualCount,
    required this.mutualUsernames,
    required this.cursor,
    this.avatarPath,
  });

  factory FollowSuggestion.fromRow(Map<String, dynamic> row) {
    final userId = row['user_id'] as String;
    return FollowSuggestion(
      userId: userId,
      username: row['username'] as String,
      avatarPath: row['avatar_path'] as String?,
      reason: SuggestionReason.fromWire(row['reason'] as String?),
      followsYou: (row['follows_you'] as bool?) ?? false,
      mutualCount: (row['mutual_count'] as int?) ?? 0,
      mutualUsernames: ((row['mutual_usernames'] as List?) ?? const []).cast<String>(),
      cursor: SuggestionCursor(
        tier: row['sort_tier'] as int,
        rank: row['sort_rank'] as int,
        userId: userId,
      ),
    );
  }

  final String userId;
  final String username;
  final String? avatarPath;
  final SuggestionReason reason;
  final bool followsYou;

  /// How many people the viewer follows also follow this account. The server
  /// counts only mutuals it may name, so this never exceeds what the label is
  /// allowed to say.
  final int mutualCount;

  /// Up to two of those mutuals, most-followed first.
  final List<String> mutualUsernames;

  final SuggestionCursor cursor;

  /// The same uuid-keyed gradient as [Profile.placeholderColors], so a person
  /// looks the same on a card as on their profile.
  List<Color> get placeholderColors =>
      Profile(id: userId, username: username, followerCount: 0, followingCount: 0).placeholderColors;
}

/// The line under a suggestion's username.
///
/// [short] is the profile row's card, which has room for one name; See all
/// names two. Names come only from [FollowSuggestion.mutualUsernames], which
/// the server has already filtered, so a block-paired mutual can never appear
/// here.
String suggestionReasonText(FollowSuggestion s, {bool short = false}) {
  final followsYou = s.followsYou ? 'Follows you' : null;
  if (s.reason != SuggestionReason.mutuals) {
    return switch (s.reason) {
      SuggestionReason.followsYou => 'Follows you',
      _ => 'Popular',
    };
  }

  final names = s.mutualUsernames;
  final n = s.mutualCount;
  String others(int k) => k == 1 ? '1 other' : '$k others';

  final String mutuals;
  if (names.isEmpty) {
    mutuals = n == 1 ? 'Followed by 1 person you follow' : 'Followed by $n people you follow';
  } else if (n <= 1) {
    mutuals = 'Followed by ${names[0]}';
  } else if (short || names.length < 2) {
    mutuals = 'Followed by ${names[0]} and ${others(n - 1)}';
  } else if (n == 2) {
    mutuals = 'Followed by ${names[0]} and ${names[1]}';
  } else {
    mutuals = 'Followed by ${names[0]}, ${names[1]} and ${others(n - 2)}';
  }

  return followsYou == null ? mutuals : '$followsYou · $mutuals';
}
