import 'package:flutter/material.dart';

import '../../data/feed_repository.dart';
import '../../data/story_repository.dart';
import '../../models/feed_post.dart';
import '../../models/story.dart';
import '../../utils/greek_date.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/feed_post_card.dart';
import '../widgets/story_picker_sheet.dart';
import 'story_viewer_screen.dart';

/// The feed: `public.get_feed` below the divider, `public.get_story_rails`
/// above it. Both keyset/bounded, neither one a mock any more.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key, this.repository, this.storyRepository});

  /// Injectable so widget tests can drive the list without a live Supabase
  /// client, the same way [FollowButton] and the profile screen take one.
  final FeedRepository? repository;

  /// Separate from [repository] because the story row is a separate query with
  /// a separate failure mode: an empty or broken rail must not take the feed
  /// below it down with it.
  final StoryRepository? storyRepository;

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  late final FeedRepository _repo = widget.repository ?? FeedRepository();
  late final StoryRepository _stories = widget.storyRepository ?? StoryRepository();
  final _scroll = ScrollController();

  final List<FeedPost> _posts = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _failed = false;

  final List<StoryRail> _rails = [];

  /// Cover URLs by story id. Signed, and only good for 60 seconds — they are
  /// re-fetched whenever the rail is, never persisted.
  Map<String, String> _railCovers = {};

  static const _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
    _loadRails();
  }

  /// Deliberately not part of [_load]: the story row and the feed fail
  /// independently, and a rail that cannot load should leave the feed alone
  /// (and vice versa). It is also the reason nothing here touches `_failed`.
  Future<void> _loadRails() async {
    try {
      final rails = await _stories.fetchRails();
      final covers = await _stories.signedViewUrls(
        rails.map((r) => r.coverStoryId).toList(),
      );
      if (!mounted) return;
      setState(() {
        _rails
          ..clear()
          ..addAll(rails);
        _railCovers = covers;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _rails.clear();
        _railCovers = {};
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || !_hasMore || _loading) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });

    try {
      final page = await _repo.fetchFeed(limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _posts
          ..clear()
          ..addAll(page);
        // A short page means the end. Asking for one more row to be sure
        // would cost a round trip on every refresh to learn something the
        // next scroll finds out for free.
        _hasMore = page.length >= _pageSize;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_posts.isEmpty) return;
    setState(() => _loadingMore = true);

    try {
      // The cursor is the last row we hold, not a page number: rows inserted
      // above it while the user reads cannot shift this page's boundary the
      // way an offset would.
      final page = await _repo.fetchFeed(after: _posts.last, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _posts.addAll(page);
        _hasMore = page.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hasMore = false;
        _loadingMore = false;
      });
    }
  }

  /// Optimistic, then reconciled: the pill moves on tap, and rolls back if
  /// the insert is refused (the post's party can stop being accessible
  /// between the fetch and the tap — a block, or a party going private).
  Future<void> _toggleLike(int index) async {
    final before = _posts[index];
    final liked = !before.likedByMe;
    setState(() => _posts[index] = before.withLike(liked));

    try {
      if (liked) {
        await _repo.like(before.postId);
      } else {
        await _repo.unlike(before.postId);
      }
    } catch (_) {
      if (!mounted) return;
      final at = _posts.indexWhere((p) => p.postId == before.postId);
      if (at != -1) setState(() => _posts[at] = before);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Δεν έγινε. Δοκίμασε ξανά.'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  void _bumpCommentCount(String postId, int delta) {
    final at = _posts.indexWhere((p) => p.postId == postId);
    if (at == -1) return;
    setState(() {
      _posts[at] = _posts[at].copyWith(
        commentCount: (_posts[at].commentCount + delta).clamp(0, 1 << 30),
      );
    });
  }

  void _removePost(String postId) {
    setState(() => _posts.removeWhere((p) => p.postId == postId));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () => Future.wait([_load(), _loadRails()]),
          child: ListView(
            key: const ValueKey('feed-list'),
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              _header(context),
              const SizedBox(height: 2),
              _storyRow(context),
              const SizedBox(height: 16),
              Container(height: 1, color: Colors.white.withValues(alpha: 0.07), margin: const EdgeInsets.only(bottom: 16)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Column(children: _feedBody()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _feedBody() {
    if (_loading) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ];
    }

    if (_failed) {
      return [_notice('Δεν φόρτωσε το feed.', action: ('Δοκίμασε ξανά', _load))];
    }

    if (_posts.isEmpty) {
      return [
        _notice(
          'Ήσυχα εδώ.\nΑκολούθησε κόσμο ή δήλωσε συμμετοχή σε πάρτι\nκαι θα γεμίσει.',
        ),
      ];
    }

    return [
      for (var i = 0; i < _posts.length; i++)
        FeedPostCard(
          key: ValueKey(_posts[i].postId),
          post: _posts[i],
          repository: _repo,
          currentUserId: _repo.currentUserId,
          onToggleLike: () => _toggleLike(i),
          onCommentCountChanged: (delta) => _bumpCommentCount(_posts[i].postId, delta),
          onHidden: () => _removePost(_posts[i].postId),
        ),
      if (_loadingMore)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
    ];
  }

  Widget _notice(String message, {(String, VoidCallback)? action}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.textAlpha(0.55)),
          ),
          if (action != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: OutlinedButton(
                onPressed: action.$2,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                  foregroundColor: AppColors.text,
                ),
                child: Text(action.$1, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('MyParty', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
          Row(
            children: [
              OutlinedButton(
                onPressed: _startStory,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                  foregroundColor: AppColors.text,
                ),
                child: const Text('+ Story', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 9),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withValues(alpha: 0.14))),
                child: Stack(
                  children: [
                    const Center(child: Icon(Icons.notifications_none, size: 16, color: AppColors.text)),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: AppColors.pink, shape: BoxShape.circle)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Opens the picker, and re-reads the rail if something was actually
  /// uploaded — the new story is the party's newest frame, so the tile's cover
  /// changes and a rail may appear that was not there before.
  Future<void> _startStory() async {
    final uploaded = await showStoryPickerSheet(context, repository: _stories);
    if (uploaded == true && mounted) _loadRails();
  }

  Widget _storyRow(BuildContext context) {
    return SizedBox(
      height: 146,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          GestureDetector(
            onTap: _startStory,
            child: Container(
              width: 104,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.2), style: BorderStyle.solid),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(gradient: LinearGradient(colors: [AppColors.purpleDeep, AppColors.pink]), shape: BoxShape.circle),
                    child: const Icon(Icons.add, color: Colors.white, size: 19),
                  ),
                  const SizedBox(height: 9),
                  Text('Ανέβασε\nστο πάρτι σου',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, height: 1.3, color: AppColors.textAlpha(0.6))),
                ],
              ),
            ),
          ),
          for (final rail in _rails) _storyTile(context, rail),
        ],
      ),
    );
  }

  /// One party's tile: its newest frame as the cover, a bright ring while there
  /// is something in it this user has not watched.
  ///
  /// The cover image is a 60-second signed URL like every other story frame —
  /// there are no durable URLs into the `story-media` bucket — so a rail that
  /// sits on screen long enough will fall back to the striped placeholder
  /// rather than showing a broken image. Refreshing the feed re-signs it.
  Widget _storyTile(BuildContext context, StoryRail rail) {
    final accent = rail.isPrivate ? AppColors.pink : AppColors.purple;
    final coverUrl = _railCovers[rail.coverStoryId];

    return GestureDetector(
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => StoryViewerScreen(
              partyId: rail.partyId,
              partyTitle: rail.partyTitle,
              isPrivate: rail.isPrivate,
            ),
          ),
        );
        // Watching the reel is what clears the ring, and it also may have
        // emptied the rail (the author took their own frames down), so the row
        // is re-read rather than patched locally.
        if (mounted) _loadRails();
      },
      child: Container(
        width: 104,
        margin: const EdgeInsets.only(right: 10),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: rail.hasUnseen ? accent : Colors.white.withValues(alpha: 0.16),
            width: rail.hasUnseen ? 2 : 1,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (coverUrl != null)
              Image.network(
                coverUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _coverPlaceholder(rail),
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : _coverPlaceholder(rail),
              )
            else
              _coverPlaceholder(rail),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [AppColors.bg.withValues(alpha: 0.92), Colors.transparent],
                  stops: const [0.42, 1],
                ),
              ),
            ),
            Positioned(
              top: 7,
              left: 7,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(formatPostAge(rail.latestAt.toUtc()), style: AppTextStyles.mono(size: 8.5)),
              ),
            ),
            if (rail.isPrivate)
              Positioned(
                top: 7,
                right: 7,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: AppColors.pink.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Icon(Icons.lock, size: 9, color: Colors.white),
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(rail.partyTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, height: 1.2)),
                  Text('${rail.storyCount} stories',
                      style: TextStyle(fontSize: 9.5, color: AppColors.textAlpha(0.6))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverPlaceholder(StoryRail rail) => DiagonalStripePlaceholder(
        colors: rail.isPrivate
            ? const [Color(0xFF1C1622), Color(0xFF151020)]
            : const [Color(0xFF191428), Color(0xFF130F20)],
      );
}

// The const `mpStory` frames and the four hardcoded tiles that used to live
// here (taratsa / vinyl / maria / kapsimo) are gone: the row above is
// public.get_story_rails, and the viewer behind it is public.get_party_stories.
