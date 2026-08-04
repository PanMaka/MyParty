class FeedPost {
  final String id;
  final String authorName;
  final String authorAvatarUrl;
  final String postedAgo;
  final String locationName;
  final String caption;
  final String imageUrl;
  final String imageBadge;
  final int likeCount;
  final int commentCount;

  const FeedPost({
    required this.id,
    required this.authorName,
    required this.authorAvatarUrl,
    required this.postedAgo,
    required this.locationName,
    required this.caption,
    required this.imageUrl,
    required this.imageBadge,
    required this.likeCount,
    required this.commentCount,
  });
}
