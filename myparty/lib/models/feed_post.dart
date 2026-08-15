/// One row of `public.get_feed`. Replaces the hardcoded `_KapsimoCard` that
/// stood in for the feed until Phase 4.
///
/// [likeCount]/[commentCount] are the denormalized counters maintained by
/// trigger — never a `count(*)` at read time — so they arrive with the row
/// and are cheap to render.
class FeedPost {
  final String postId;
  final String partyId;
  final String partyTitle;
  final bool partyIsPrivate;
  final String authorId;
  final String authorUsername;
  final String? body;
  final String? mediaPath;
  final int likeCount;
  final int commentCount;
  final bool likedByMe;
  final DateTime createdAt;

  const FeedPost({
    required this.postId,
    required this.partyId,
    required this.partyTitle,
    required this.partyIsPrivate,
    required this.authorId,
    required this.authorUsername,
    required this.body,
    required this.mediaPath,
    required this.likeCount,
    required this.commentCount,
    required this.likedByMe,
    required this.createdAt,
  });

  factory FeedPost.fromRow(Map<String, dynamic> row) {
    return FeedPost(
      postId: row['post_id'] as String,
      partyId: row['party_id'] as String,
      partyTitle: row['party_title'] as String,
      partyIsPrivate: (row['party_is_private'] as bool?) ?? false,
      authorId: row['author_id'] as String,
      authorUsername: row['author_username'] as String,
      body: row['body'] as String?,
      mediaPath: row['media_path'] as String?,
      likeCount: (row['like_count'] as int?) ?? 0,
      commentCount: (row['comment_count'] as int?) ?? 0,
      likedByMe: (row['liked_by_me'] as bool?) ?? false,
      // Kept in UTC, unlike RsvpParty.startsAt: this is the keyset cursor as
      // well as a display value, and it has to go back to the RPC exactly as
      // it came out.
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  /// Optimistic local echo of a like/unlike, so the pill responds before the
  /// insert round-trips. The server counter stays authoritative — the next
  /// page fetch overwrites this.
  FeedPost withLike(bool liked) {
    if (liked == likedByMe) return this;
    return copyWith(
      likedByMe: liked,
      likeCount: liked ? likeCount + 1 : (likeCount - 1).clamp(0, 1 << 30),
    );
  }

  FeedPost copyWith({int? likeCount, int? commentCount, bool? likedByMe}) {
    return FeedPost(
      postId: postId,
      partyId: partyId,
      partyTitle: partyTitle,
      partyIsPrivate: partyIsPrivate,
      authorId: authorId,
      authorUsername: authorUsername,
      body: body,
      mediaPath: mediaPath,
      likeCount: likeCount ?? this.likeCount,
      commentCount: commentCount ?? this.commentCount,
      likedByMe: likedByMe ?? this.likedByMe,
      createdAt: createdAt,
    );
  }
}

/// One `public.post_comments` row, with its author's username joined in.
class PostComment {
  final String id;
  final String postId;
  final String authorId;
  final String authorUsername;
  final String body;
  final DateTime createdAt;

  const PostComment({
    required this.id,
    required this.postId,
    required this.authorId,
    required this.authorUsername,
    required this.body,
    required this.createdAt,
  });

  factory PostComment.fromRow(Map<String, dynamic> row) {
    final author = row['profiles'] as Map<String, dynamic>?;
    return PostComment(
      id: row['id'] as String,
      postId: row['post_id'] as String,
      authorId: row['author_id'] as String,
      authorUsername: (author?['username'] as String?) ?? '',
      body: row['body'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}

/// What a report points at — mirrors `public.report_target_type`.
enum ReportTarget {
  post('post'),
  comment('comment'),
  party('party'),
  profile('profile');

  const ReportTarget(this.wireName);

  final String wireName;
}
