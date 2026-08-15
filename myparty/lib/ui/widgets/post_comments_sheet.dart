import 'package:flutter/material.dart';

import '../../data/feed_repository.dart';
import '../../models/feed_post.dart';
import '../../utils/greek_date.dart';
import '../theme/app_theme.dart';
import 'report_sheet.dart';

/// Comments on a post.
///
/// [onCountChanged] fires with +1/-1 as comments are added or removed, so the
/// card that opened this can move its pill without refetching the feed. A
/// callback rather than a return value because a bottom sheet dismissed by
/// dragging pops with null — the count would be lost exactly when the user
/// leaves the normal way. The trigger-maintained `comment_count` stays
/// authoritative; this is only the local echo until the next page load.
Future<void> showPostCommentsSheet(
  BuildContext context, {
  required FeedPost post,
  required ValueChanged<int> onCountChanged,
  FeedRepository? repository,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CommentsSheet(
      post: post,
      onCountChanged: onCountChanged,
      repository: repository ?? FeedRepository(),
    ),
  );
}

class _CommentsSheet extends StatefulWidget {
  const _CommentsSheet({
    required this.post,
    required this.onCountChanged,
    required this.repository,
  });

  final FeedPost post;
  final ValueChanged<int> onCountChanged;
  final FeedRepository repository;

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  final List<PostComment> _comments = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _failed = false;

  String? get _uid => widget.repository.currentUserId;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || !_hasMore) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 240) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    try {
      final page = await widget.repository.fetchComments(widget.post.postId);
      if (!mounted) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(page);
        _hasMore = page.length >= 30;
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
    if (_comments.isEmpty) return;
    setState(() => _loadingMore = true);

    try {
      final page = await widget.repository
          .fetchComments(widget.post.postId, after: _comments.last);
      if (!mounted) return;
      setState(() {
        _comments.addAll(page);
        _hasMore = page.length >= 30;
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

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty) return;
    _input.clear();

    try {
      await widget.repository.comment(widget.post.postId, body);
      if (!mounted) return;
      widget.onCountChanged(1);
      // Refetch the first page rather than splicing a fabricated row in:
      // the server assigns id and created_at, and both are the keyset this
      // list pages on.
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Δεν στάλθηκε.'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _hide(PostComment comment) async {
    try {
      await widget.repository.hideComment(comment.id);
      if (!mounted) return;
      setState(() => _comments.removeWhere((c) => c.id == comment.id));
      widget.onCountChanged(-1);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Δεν διαγράφηκε.'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        decoration: const BoxDecoration(
          color: AppColors.sheet,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text('Σχόλια',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            ),
            Flexible(child: _body()),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        style: const TextStyle(fontSize: 13.5),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Γράψε ένα σχόλιο…',
                          hintStyle: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.4)),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.05),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: AppColors.hairline),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: AppColors.hairline),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _send,
                      icon: const Icon(Icons.send, size: 19, color: AppColors.purpleLight),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 42),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_failed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 42),
        child: Center(
          child: Text('Δεν φόρτωσαν τα σχόλια.',
              style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.55))),
        ),
      );
    }

    if (_comments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 42),
        child: Center(
          child: Text('Κανένα σχόλιο ακόμη.',
              style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.55))),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      itemCount: _comments.length + (_loadingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _comments.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        return _tile(_comments[i]);
      },
    );
  }

  Widget _tile(PostComment comment) {
    final mine = comment.authorId == _uid;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(comment.authorUsername,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 7),
                    Text(formatPostAge(comment.createdAt),
                        style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.45))),
                  ],
                ),
                const SizedBox(height: 3),
                Text(comment.body,
                    style: TextStyle(fontSize: 13, height: 1.35, color: AppColors.textAlpha(0.85))),
              ],
            ),
          ),
          _overflow(comment, mine),
        ],
      ),
    );
  }

  Widget _overflow(PostComment comment, bool mine) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz, size: 17, color: AppColors.textAlpha(0.45)),
      color: AppColors.sheet,
      onSelected: (value) {
        if (value == 'report') {
          showReportSheet(
            context,
            target: ReportTarget.comment,
            targetId: comment.id,
            repository: widget.repository,
          );
        } else {
          _hide(comment);
        }
      },
      itemBuilder: (_) => [
        // Report is offered on someone else's comment only — reporting your
        // own is noise in the queue, and you can just delete it.
        if (!mine)
          const PopupMenuItem(value: 'report', child: Text('Αναφορά', style: TextStyle(fontSize: 13))),
        if (mine)
          const PopupMenuItem(value: 'delete', child: Text('Διαγραφή', style: TextStyle(fontSize: 13))),
      ],
    );
  }
}
