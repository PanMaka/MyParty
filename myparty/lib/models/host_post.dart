/// One `public.party_posts` row as a party's own screen needs it.
///
/// Deliberately NOT [FeedPost]. That model carries `partyTitle`,
/// `authorUsername` and `likedByMe`, which exist because `get_feed` returns
/// posts from many parties by many authors and a feed card has to say whose
/// party it is looking at. On a party's own surface all three are already
/// known from context — the party is the one being rendered, and since
/// 20260825095311 the author is always its host — so reusing [FeedPost] would
/// mean either a join fetching columns nothing displays, or three fields
/// filled with values invented at the call site.
///
/// [mediaPath] is a storage key into the private `post-media` bucket, never a
/// URL. Resolving it needs a signed URL from
/// [FeedRepository.signedPostMediaUrls] — the same arrangement `cover_path`
/// and `avatar_path` have.
class HostPost {
  final String id;
  final String partyId;

  /// Null for a photo the host posted with no caption. `party_posts` allows
  /// either half to be absent but not both (`party_posts_not_empty`).
  final String? body;

  /// Null for a text-only post. A row whose media has been declared but not
  /// confirmed never arrives here at all — the SELECT policy hides it until
  /// `confirm_post_upload` has checked the bytes are really in the bucket, so
  /// a non-null path here means the object exists.
  final String? mediaPath;

  final int likeCount;
  final int commentCount;

  /// UTC, like [FeedPost.createdAt]: it doubles as a sort key and should not
  /// pick up a local-time offset on the way through.
  final DateTime createdAt;

  const HostPost({
    required this.id,
    required this.partyId,
    required this.body,
    required this.mediaPath,
    required this.likeCount,
    required this.commentCount,
    required this.createdAt,
  });

  factory HostPost.fromRow(Map<String, dynamic> row) {
    return HostPost(
      id: row['id'] as String,
      partyId: row['party_id'] as String,
      body: row['body'] as String?,
      mediaPath: row['media_path'] as String?,
      likeCount: (row['like_count'] as int?) ?? 0,
      commentCount: (row['comment_count'] as int?) ?? 0,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  bool get hasMedia => mediaPath != null;
}
