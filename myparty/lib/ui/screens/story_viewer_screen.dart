import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/story_repository.dart';
import '../../models/story.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';

/// Full-screen story viewer: one party's reel, oldest frame first.
///
/// Everything on screen is a real `public.stories` row. The media itself is
/// fetched through 60-second signed URLs, because the `story-media` bucket has
/// no storage policies at all — there is no such thing as a durable URL for a
/// story frame, by design.
class StoryViewerScreen extends StatefulWidget {
  const StoryViewerScreen({
    super.key,
    required this.partyId,
    this.partyTitle,
    this.isPrivate = false,
    this.repository,
  });

  final String partyId;

  /// Shown in the header. Passed in by whoever opened the reel (the feed rail
  /// knows it already) rather than fetched again here.
  final String? partyTitle;
  final bool isPrivate;

  /// Injectable so widget tests can drive the reel without a live Supabase
  /// client, the same way [ChatScreen] and [FeedScreen] take one.
  final StoryRepository? repository;

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  static const _frameDuration = Duration(seconds: 5);

  late final StoryRepository _repo = widget.repository ?? StoryRepository();

  final List<Story> _stories = [];
  Map<String, String> _urls = {};
  int _index = 0;
  bool _loading = true;
  bool _failed = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });

    try {
      final stories = await _repo.fetchPartyStories(widget.partyId);
      // Ids the caller may not see come back with no URL — an author blocked
      // between the two calls, or a frame that expired in the gap. Dropping
      // them here is what keeps the reel from showing a dead rectangle.
      final urls = await _repo.signedViewUrls(stories.map((s) => s.id).toList());

      if (!mounted) return;
      setState(() {
        _stories
          ..clear()
          ..addAll(stories.where((s) => urls.containsKey(s.id) || s.isVideo));
        _urls = urls;
        _index = 0;
        _loading = false;
      });

      if (_stories.isNotEmpty) _onFrameShown();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  /// Restarts the frame timer and records the view. Fire-and-forget: the
  /// composite primary key on `story_views` makes a repeat insert a no-op, so
  /// there is nothing to reconcile if it fails or races a second device.
  void _onFrameShown() {
    _timer?.cancel();
    _timer = Timer(_frameDuration, _advance);

    final story = _stories[_index];
    if (!story.viewed) {
      _repo.markViewed(story.id).catchError((_) {});
      setState(() {
        _stories[_index] = story.copyWith(
          viewed: true,
          viewCount: story.viewCount + 1,
        );
      });
    }
  }

  void _advance() {
    if (_index >= _stories.length - 1) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _index++);
    _onFrameShown();
  }

  void _back() {
    if (_index == 0) return;
    setState(() => _index--);
    _onFrameShown();
  }

  Future<void> _hide(Story story) async {
    _timer?.cancel();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.sheet,
        title: const Text('Κατέβασμα story;', style: TextStyle(fontSize: 16)),
        content: Text(
          'Φεύγει για όλους. Δεν μπορεί να αναιρεθεί.',
          style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Άκυρο'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Κατέβασέ το', style: TextStyle(color: AppColors.pink)),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      if (mounted && _stories.isNotEmpty) _onFrameShown();
      return;
    }

    try {
      await _repo.hideStory(story.id);
      if (!mounted) return;
      setState(() {
        _stories.removeWhere((s) => s.id == story.id);
        if (_index >= _stories.length) _index = _stories.length - 1;
      });
      if (_stories.isEmpty) {
        Navigator.of(context).maybePop();
      } else {
        _onFrameShown();
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Δεν έγινε. Δοκίμασε ξανά.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (_stories.isNotEmpty) _onFrameShown();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? _message('Κάτι πήγε στραβά.', retry: true)
              : _stories.isEmpty
                  ? _message('Κανένα story εδώ — ακόμα.')
                  : _reel(),
    );
  }

  Widget _message(String text, {bool retry = false}) {
    return SafeArea(
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(text, style: TextStyle(fontSize: 14, color: AppColors.textAlpha(0.7))),
                if (retry) ...[
                  const SizedBox(height: 10),
                  TextButton(onPressed: _load, child: const Text('Δοκίμασε ξανά')),
                ],
              ],
            ),
          ),
          Positioned(top: 8, right: 12, child: _closeButton()),
        ],
      ),
    );
  }

  Widget _reel() {
    final story = _stories[_index];
    final isMine = story.authorId == _repo.currentUserId;

    return GestureDetector(
      // Left third goes back, the rest advances — the gesture every story
      // viewer has, and the reason the timer is restarted rather than resumed.
      onTapUp: (details) {
        final width = MediaQuery.of(context).size.width;
        if (details.localPosition.dx < width / 3) {
          _back();
        } else {
          _advance();
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          _frame(story),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      for (var i = 0; i < _stories.length; i++)
                        Expanded(
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            height: 2.5,
                            decoration: BoxDecoration(
                              color: i < _index
                                  ? Colors.white
                                  : (i == _index
                                      ? Colors.white.withValues(alpha: 0.85)
                                      : Colors.white.withValues(alpha: 0.28)),
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _header(story, isMine),
                ],
              ),
            ),
          ),
          Positioned(left: 12, bottom: 40, child: _byline(story, isMine)),
        ],
      ),
    );
  }

  Widget _frame(Story story) {
    if (story.isVideo) {
      // Video playback needs a player package this app does not carry yet;
      // uploads are images only, so this is only reachable for rows created
      // outside the app. Rendered as a labelled placeholder rather than a
      // blank screen so it is obvious what it is.
      return const DiagonalStripePlaceholder(
        colors: [Color(0xFF221A2E), Color(0xFF181228)],
        label: 'video',
      );
    }

    final url = _urls[story.id];
    if (url == null) {
      return const DiagonalStripePlaceholder(colors: [Color(0xFF221A2E), Color(0xFF181228)]);
    }

    return Image.network(
      url,
      fit: BoxFit.cover,
      // A signed URL lives 60 seconds. If the frame is reached after it has
      // lapsed the image simply fails, and a striped placeholder is a better
      // answer than a broken-image glyph.
      errorBuilder: (_, _, _) => const DiagonalStripePlaceholder(
        colors: [Color(0xFF221A2E), Color(0xFF181228)],
      ),
      loadingBuilder: (_, child, progress) => progress == null
          ? child
          : const DiagonalStripePlaceholder(colors: [Color(0xFF1B1D33), Color(0xFF141426)]),
    );
  }

  Widget _header(Story story, bool isMine) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.isPrivate ? AppColors.pink : AppColors.purple,
              width: 1.5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: const DiagonalStripePlaceholder(colors: [Color(0xFF241E3C), Color(0xFF1B1630)]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.partyTitle ?? 'Story',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
              ),
              Text(
                '${_index + 1} από ${_stories.length} · ${_expiryLabel(story)}',
                style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.55)),
              ),
            ],
          ),
        ),
        if (isMine)
          GestureDetector(
            onTap: () => _hide(story),
            child: Container(
              width: 30,
              height: 30,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.delete_outline, size: 15, color: Colors.white),
            ),
          ),
        _closeButton(),
      ],
    );
  }

  Widget _closeButton() {
    return GestureDetector(
      onTap: () => Navigator.of(context).maybePop(),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.close, size: 15, color: Colors.white),
      ),
    );
  }

  Widget _byline(Story story, bool isMine) {
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 6, 11, 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(color: Color(0xFF2E1F28), shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            isMine ? 'Εσύ' : story.authorUsername,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
          Text(
            _clock(story.createdAt.toLocal()),
            style: AppTextStyles.mono(size: 9.5, color: AppColors.textAlpha(0.5)),
          ),
          // The view count is the author's alone: story_views' SELECT policy
          // only ever returns your own rows, so this number is the aggregate
          // counter and never a list of who watched.
          if (isMine) ...[
            const SizedBox(width: 8),
            const Icon(Icons.visibility_outlined, size: 12, color: Colors.white70),
            const SizedBox(width: 3),
            Text('${story.viewCount}',
                style: AppTextStyles.mono(size: 9.5, color: AppColors.textAlpha(0.5))),
          ],
        ],
      ),
    );
  }

  String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

  String _expiryLabel(Story story) {
    final left = story.remaining(DateTime.now());
    if (left.isNegative) return 'έληξε';
    if (left.inHours >= 1) return 'σβήνει σε ${left.inHours}ω';
    return 'σβήνει σε ${left.inMinutes}λ';
  }
}
