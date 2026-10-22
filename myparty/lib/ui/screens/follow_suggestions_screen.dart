import 'package:flutter/material.dart';

import '../../data/social_repository.dart';
import '../../models/follow_suggestion.dart';
import '../../state/data_changes.dart';
import '../../state/live_refresh.dart';
import '../theme/app_theme.dart';
import '../widgets/follow_button.dart';
import '../widgets/mp_bottom_nav.dart' show MpTab;
import '../widgets/people_you_may_know.dart';
import '../widgets/user_link.dart';

/// "See all" from the profile's People you may know: the full list, 20 at a
/// time, newest page appended as the end comes into view.
///
/// Keyset, like every unbounded list here. The cursor is the last row the
/// SERVER sent, kept apart from the rows on screen: a dismissal removes a row
/// locally, and using what is left on screen as the cursor would re-request
/// rows already shown. The server re-ranks on every call, so a row can shift
/// between pages; rows are de-duplicated by user id on the way in.
class FollowSuggestionsScreen extends StatefulWidget {
  const FollowSuggestionsScreen({super.key, required this.social, required this.avatarUrl});

  final SocialRepository social;
  final String? Function(String? path) avatarUrl;

  @override
  State<FollowSuggestionsScreen> createState() => _FollowSuggestionsScreenState();
}

class _FollowSuggestionsScreenState extends State<FollowSuggestionsScreen>
    with LiveRefresh<FollowSuggestionsScreen> {
  static const _pageSize = 20;

  List<FollowSuggestion>? _items;

  /// Followed from this list (or anywhere) since it was built. A lazily built
  /// list recreates a card scrolled back into view, and its [FollowButton]
  /// would otherwise start from "Follow" again; this is what it starts from.
  final Set<String> _followed = {};
  SuggestionCursor? _cursor;
  bool _exhausted = false;
  bool _loadingMore = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loadFirst();
  }

  @override
  MpTab? get liveTab => null;

  @override
  Future<void> liveRefresh() => _loadFirst();

  @override
  void onDataChange(DataChange change) {
    switch (change) {
      case FollowChanged(:final targetUserId, :final following):
        setState(() => following ? _followed.add(targetUserId) : _followed.remove(targetUserId));
      case SuggestionDismissed(:final userId, dismissed: true):
        _remove(userId);
      case SuggestionDismissed(dismissed: false):
        refreshWhenVisible();
      case BlockChanged(:final userId, :final blocked):
        if (blocked) _remove(userId);
        refreshWhenVisible();
      default:
        break;
    }
  }

  Future<void> _loadFirst() async {
    try {
      final page = await widget.social.fetchFollowSuggestions(limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _items = page;
        _cursor = page.isEmpty ? null : page.last.cursor;
        _exhausted = page.length < _pageSize;
        _failed = false;
      });
    } catch (_) {
      if (mounted && _items == null) setState(() => _failed = true);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted || _cursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.social.fetchFollowSuggestions(after: _cursor, limit: _pageSize);
      if (!mounted) return;
      final seen = {for (final s in _items ?? const <FollowSuggestion>[]) s.userId};
      setState(() {
        _items = [...?_items, ...page.where((s) => !seen.contains(s.userId))];
        if (page.isNotEmpty) _cursor = page.last.cursor;
        _exhausted = page.length < _pageSize;
      });
    } catch (_) {
      // The next scroll to the end tries again.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  int _remove(String userId) {
    final items = _items;
    if (items == null) return -1;
    final index = items.indexWhere((s) => s.userId == userId);
    if (index >= 0) setState(() => _items = [...items]..removeAt(index));
    return index;
  }

  void _restore(FollowSuggestion s, int index) {
    if (!mounted) return;
    final items = _items ?? const <FollowSuggestion>[];
    if (items.any((x) => x.userId == s.userId)) return;
    setState(() => _items = [...items]..insert(index.clamp(0, items.length), s));
  }

  void _dismiss(FollowSuggestion s) {
    var index = -1;
    dismissSuggestionWithUndo(
      context: context,
      social: widget.social,
      suggestion: s,
      remove: () => index = _remove(s.userId),
      restore: () => _restore(s, index),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: const Text('People you may know', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    final items = _items;

    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Suggestions didn’t load.', style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.6))),
            TextButton(onPressed: _loadFirst, child: const Text('Try again')),
          ],
        ),
      );
    }

    if (items == null) return const Center(child: CircularProgressIndicator());

    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No suggestions right now.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.5)),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFirst,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 300) _loadMore();
          return false;
        },
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: items.length + (_loadingMore ? 1 : 0),
          separatorBuilder: (_, _) => Container(height: 1, color: AppColors.hairline),
          itemBuilder: (_, i) {
            if (i >= items.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return _row(items[i]);
          },
        ),
      ),
    );
  }

  Widget _row(FollowSuggestion s) {
    return Padding(
      key: ValueKey(s.userId),
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: UserLink(
              userId: s.userId,
              username: s.username,
              child: Row(
                children: [
                  SuggestionAvatar(suggestion: s, url: widget.avatarUrl(s.avatarPath), size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.username,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          suggestionReasonText(s),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.5)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          FollowButton(
            targetUserId: s.userId,
            compact: true,
            repository: widget.social,
            initialFollowing: _followed.contains(s.userId),
          ),
          IconButton(
            tooltip: 'Dismiss',
            onPressed: () => _dismiss(s),
            icon: Icon(Icons.close, size: 18, color: AppColors.textAlpha(0.45)),
          ),
        ],
      ),
    );
  }
}
