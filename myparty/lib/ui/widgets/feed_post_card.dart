import 'package:flutter/material.dart';

import '../../data/feed_repository.dart';
import '../../models/feed_post.dart';
import '../../models/mp_party.dart';
import '../../utils/greek_date.dart';
import '../theme/app_theme.dart';
import 'diagonal_placeholder.dart';
import 'follow_button.dart';
import 'post_comments_sheet.dart';
import 'privacy_badge.dart';
import 'report_sheet.dart';

/// One real `party_posts` row. Replaces `_KapsimoCard`, which hardcoded a
/// single design-mock post and pulled its like count out of `MpStore._likes`.
///
/// Stateless: the like toggle and comment count are owned by the feed's list
/// state, so a rebuild of the list (a refresh, a new page) cannot leave a
/// card holding a stale copy of a counter the server has since moved.
class FeedPostCard extends StatelessWidget {
  const FeedPostCard({
    super.key,
    required this.post,
    required this.onToggleLike,
    required this.onCommentCountChanged,
    required this.onHidden,
    this.currentUserId,
    this.repository,
  });

  final FeedPost post;
  final VoidCallback onToggleLike;
  final ValueChanged<int> onCommentCountChanged;
  final VoidCallback onHidden;

  /// Read once by the feed and passed down, rather than each card asking the
  /// auth client — see [FeedRepository.currentUserId].
  final String? currentUserId;

  final FeedRepository? repository;

  FeedRepository get _repo => repository ?? FeedRepository();

  bool get _mine => currentUserId != null && post.authorId == currentUserId;

  Future<void> _hide(BuildContext context) async {
    try {
      await _repo.hidePost(post.postId);
      onHidden();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Δεν διαγράφηκε.'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
        color: Colors.white.withValues(alpha: 0.03),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context),
          if (post.mediaPath != null)
            const SizedBox(
              height: 190,
              child: DiagonalStripePlaceholder(
                colors: [Color(0xFF1A1522), Color(0xFF141020)],
                // The post-media bucket is private and signed-URL only, so
                // there is nothing to render until the signing endpoint
                // lands. A placeholder beats a broken image.
                label: 'φωτό',
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 12, 13, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (post.body != null && post.body!.isNotEmpty)
                  Text(post.body!,
                      style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.textAlpha(0.85))),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      _reactionPill(
                        onTap: onToggleLike,
                        gradientDot: true,
                        active: post.likedByMe,
                        label: '${post.likeCount}',
                      ),
                      const SizedBox(width: 8),
                      _reactionPill(
                        onTap: () => showPostCommentsSheet(
                          context,
                          post: post,
                          onCountChanged: onCommentCountChanged,
                          repository: _repo,
                        ),
                        icon: Icons.chat_bubble_outline,
                        label: '${post.commentCount}',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(13),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(11)),
            child: DiagonalStripePlaceholder(
              colors: _avatarColors(post.authorId),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(post.authorUsername,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 6),
                    PrivacyBadge(
                      type: post.partyIsPrivate ? MpPartyType.private : MpPartyType.public,
                    ),
                  ],
                ),
                Text('${formatPostAge(post.createdAt)} · ${post.partyTitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.5))),
              ],
            ),
          ),
          // The follow button is on the post's author, which is a real
          // profiles row — the mock card had a local bool because "Kápsimo"
          // had no id to follow.
          if (!_mine) ...[
            FollowButton(targetUserId: post.authorId, compact: true),
            const SizedBox(width: 2),
          ],
          _overflow(context),
        ],
      ),
    );
  }

  Widget _overflow(BuildContext context) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz, size: 19, color: AppColors.textAlpha(0.5)),
      color: AppColors.sheet,
      onSelected: (value) {
        switch (value) {
          case 'report':
            showReportSheet(
              context,
              target: ReportTarget.post,
              targetId: post.postId,
              repository: _repo,
            );
          case 'report_party':
            showReportSheet(
              context,
              target: ReportTarget.party,
              targetId: post.partyId,
              repository: _repo,
            );
          case 'report_author':
            showReportSheet(
              context,
              target: ReportTarget.profile,
              targetId: post.authorId,
              repository: _repo,
            );
          case 'delete':
            _hide(context);
        }
      },
      itemBuilder: (_) => [
        if (!_mine) ...[
          const PopupMenuItem(value: 'report', child: Text('Αναφορά δημοσίευσης', style: TextStyle(fontSize: 13))),
          const PopupMenuItem(value: 'report_author', child: Text('Αναφορά χρήστη', style: TextStyle(fontSize: 13))),
        ],
        const PopupMenuItem(value: 'report_party', child: Text('Αναφορά πάρτι', style: TextStyle(fontSize: 13))),
        // hide_post also accepts the party's host, but the feed row does not
        // carry host_id, so the client only offers this on your own posts.
        // A host who needs it gets the same 42501 as anyone else here and
        // moderates from the party surface instead.
        if (_mine)
          const PopupMenuItem(value: 'delete', child: Text('Διαγραφή', style: TextStyle(fontSize: 13))),
      ],
    );
  }
}

/// Same derivation as [Profile.placeholderColors] — stable per author, so
/// the feed stops looking like it reshuffles on every rebuild.
List<Color> _avatarColors(String userId) {
  final hue = (userId.hashCode.abs() % 360).toDouble();
  return [
    HSLColor.fromAHSL(1, hue, 0.32, 0.20).toColor(),
    HSLColor.fromAHSL(1, hue, 0.30, 0.13).toColor(),
  ];
}

Widget _reactionPill({
  VoidCallback? onTap,
  IconData? icon,
  bool gradientDot = false,
  bool active = false,
  required String label,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: active
            ? AppColors.pink.withValues(alpha: 0.14)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: active ? AppColors.pink : AppColors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (gradientDot)
            Container(
              width: 13,
              height: 13,
              decoration: const BoxDecoration(gradient: AppColors.likeGradient, shape: BoxShape.circle),
            )
          else if (icon != null)
            Icon(icon, size: 15, color: AppColors.textAlpha(0.7)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );
}
