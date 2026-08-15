import 'package:flutter/material.dart';

import '../../data/feed_repository.dart';
import '../../models/feed_post.dart';
import '../../models/mp_party.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/feed_post_card.dart';
import '../widgets/story_picker_sheet.dart';
import 'story_viewer_screen.dart';

/// The feed. The story row above it is still the const `mpStory` mock — that
/// ships real in Phase 5 — but everything below the divider is now
/// `public.get_feed`, keyset-paginated.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key, this.repository});

  /// Injectable so widget tests can drive the list without a live Supabase
  /// client, the same way [FollowButton] and the profile screen take one.
  final FeedRepository? repository;

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  late final FeedRepository _repo = widget.repository ?? FeedRepository();
  final _scroll = ScrollController();

  final List<FeedPost> _posts = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _failed = false;

  static const _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
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
          onRefresh: _load,
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
                onPressed: () => showStoryPickerSheet(context),
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

  Widget _storyRow(BuildContext context) {
    return SizedBox(
      height: 146,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          GestureDetector(
            onTap: () => showStoryPickerSheet(context),
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
          _storyTile(context, 'taratsa', 'Ταράτσα στο Κουκάκι', 'Κουκάκι · 24 μέσα'),
          _storyTile(context, 'vinyl', 'Techno Δευτέρα', 'Vinyl Room · 180 μέσα', venue: true),
          _storyTile(context, 'maria', 'Γενέθλια Μαρίας', 'Εξάρχεια · 31 μέσα'),
          _kapsimoStoryTile(context),
        ],
      ),
    );
  }

  Widget _storyTile(BuildContext context, String id, String title, String sub, {bool venue = false}) {
    final party = mpParties[id]!;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => StoryViewerScreen(partyId: id)),
      ),
      child: Container(
        width: 104,
        margin: const EdgeInsets.only(right: 10),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: party.isPrivate ? AppColors.pink : AppColors.purple, width: 2),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DiagonalStripePlaceholder(colors: party.isPrivate ? const [Color(0xFF1C1622), Color(0xFF151020)] : const [Color(0xFF191428), Color(0xFF130F20)]),
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
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(99)),
                child: Text('ΤΩΡΑ', style: AppTextStyles.mono(size: 8.5)),
              ),
            ),
            Positioned(
              top: 7,
              right: 7,
              child: venue
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(5)),
                      child: Text('VENUE', style: AppTextStyles.mono(size: 7.5)),
                    )
                  : Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(color: AppColors.pink.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(5)),
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
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, height: 1.2)),
                  Text(sub, style: TextStyle(fontSize: 9.5, color: AppColors.textAlpha(0.6))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kapsimoStoryTile(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const StoryViewerScreen(partyId: 'kapsimo')),
      ),
      child: Container(
        width: 104,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.hairline)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DiagonalStripePlaceholder(colors: [Color(0xFF191428), Color(0xFF130F20)], label: 'poster\nKápsimo'),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [AppColors.bg.withValues(alpha: 0.9), Colors.transparent],
                  stops: const [0.42, 1],
                ),
              ),
            ),
            Positioned(
              top: 7,
              right: 7,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(5)),
                child: Text('VENUE', style: AppTextStyles.mono(size: 7.5)),
              ),
            ),
            const Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Kápsimo', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                  Text('Γκάζι · από 00:00', style: TextStyle(fontSize: 9.5, color: Color(0x99F4F1F8))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
