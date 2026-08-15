/// One row of `public.get_party_stories` — a single frame in a party's reel.
///
/// [mediaPath] is a key into the `story-media` bucket, never a URL. The bucket
/// has no storage policies, so bytes are only reachable through a signed URL
/// the `story-media` edge function issues after re-checking visibility; the
/// path is here so the client can key its URL cache by something stable, since
/// the signed URL itself expires in 60 seconds.
class Story {
  final String id;
  final String partyId;
  final String authorId;
  final String authorUsername;
  final String mediaPath;
  final String contentType;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int viewCount;

  /// Whether *this* user has already watched it — from their own `story_views`
  /// rows, which is all the RLS policy will ever show them. It is never a
  /// statement about anyone else.
  final bool viewed;

  const Story({
    required this.id,
    required this.partyId,
    required this.authorId,
    required this.authorUsername,
    required this.mediaPath,
    required this.contentType,
    required this.createdAt,
    required this.expiresAt,
    required this.viewCount,
    required this.viewed,
  });

  factory Story.fromRow(Map<String, dynamic> row) {
    return Story(
      id: row['id'] as String,
      partyId: row['party_id'] as String,
      authorId: row['author_id'] as String,
      authorUsername: (row['author_username'] as String?) ?? '',
      mediaPath: row['media_path'] as String,
      contentType: (row['content_type'] as String?) ?? 'image/jpeg',
      // Kept in UTC: this doubles as the keyset cursor and has to go back to
      // the RPC exactly as it came out. Same rule as PartyMessage.createdAt.
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      expiresAt: DateTime.parse(row['expires_at'] as String).toUtc(),
      viewCount: (row['view_count'] as int?) ?? 0,
      viewed: (row['viewed'] as bool?) ?? false,
    );
  }

  bool get isVideo => contentType.startsWith('video/');

  /// How long is left before the server stops serving it. Rendered as a "3ω"
  /// style hint, and also the reason the viewer never caches a reel across
  /// sessions — a frame that was live when the screen opened may not be by the
  /// time it is scrolled to.
  Duration remaining(DateTime now) => expiresAt.difference(now.toUtc());

  Story copyWith({int? viewCount, bool? viewed}) {
    return Story(
      id: id,
      partyId: partyId,
      authorId: authorId,
      authorUsername: authorUsername,
      mediaPath: mediaPath,
      contentType: contentType,
      createdAt: createdAt,
      expiresAt: expiresAt,
      viewCount: viewCount ?? this.viewCount,
      viewed: viewed ?? this.viewed,
    );
  }
}

/// One row of `public.get_story_rails` — a party as it appears in the feed's
/// story row: the tile, its cover frame, and whether there is anything new
/// behind it.
class StoryRail {
  final String partyId;
  final String partyTitle;
  final bool isPrivate;
  final int storyCount;
  final DateTime latestAt;
  final String coverStoryId;
  final String coverMediaPath;

  /// Drives the bright ring. Per-viewer, like [Story.viewed].
  final bool hasUnseen;

  const StoryRail({
    required this.partyId,
    required this.partyTitle,
    required this.isPrivate,
    required this.storyCount,
    required this.latestAt,
    required this.coverStoryId,
    required this.coverMediaPath,
    required this.hasUnseen,
  });

  factory StoryRail.fromRow(Map<String, dynamic> row) {
    return StoryRail(
      partyId: row['party_id'] as String,
      partyTitle: row['party_title'] as String,
      isPrivate: (row['party_is_private'] as bool?) ?? false,
      storyCount: (row['story_count'] as int?) ?? 0,
      latestAt: DateTime.parse(row['latest_at'] as String).toLocal(),
      coverStoryId: row['cover_story_id'] as String,
      coverMediaPath: (row['cover_media_path'] as String?) ?? '',
      hasUnseen: (row['has_unseen'] as bool?) ?? false,
    );
  }
}

/// A party the signed-in user may post a story to — the picker sheet's options.
///
/// Not a server type of its own: it is projected from the parties the user
/// hosts or has RSVP'd to, because those are the ones the `stories` INSERT
/// policy will actually accept.
class StoryTarget {
  final String partyId;
  final String title;
  final bool isPrivate;
  final DateTime startsAt;

  const StoryTarget({
    required this.partyId,
    required this.title,
    required this.isPrivate,
    required this.startsAt,
  });
}
