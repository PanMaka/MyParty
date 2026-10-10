import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/chat_repository.dart';
import '../../data/direct_chat_repository.dart';
import '../../models/chat_message.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import 'chat_screen.dart';

/// The chat list, in two tabs: **Parties** (group chats, `get_party_chats`)
/// and **Direct** (1-on-1 threads, `get_direct_chats`).
///
/// Two tabs rather than one merged list because the two lists page
/// differently: the party list is bounded by participation and arrives in one
/// call, while the Direct list grows with every person you have ever written
/// to and is keyset-paginated (CLAUDE.md #5). A merged list would need one
/// cursor across two orderings for no gain a tab does not already give.
///
/// Neither tab filters anything. The party list is exactly what
/// `can_chat_in_party` admits and the Direct list exactly the threads you are
/// a member of minus blocked peers — the RPCs apply both.
class MessagesScreen extends StatefulWidget {
  /// Injectable for tests; production callers let them default.
  final ChatRepository? repository;
  final DirectChatRepository? directRepository;

  const MessagesScreen({super.key, this.repository, this.directRepository});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  late final ChatRepository _repository = widget.repository ?? ChatRepository();
  late final DirectChatRepository _direct = widget.directRepository ?? DirectChatRepository();
  late Future<List<PartyChatSummary>> _chatsFuture;

  @override
  void initState() {
    super.initState();
    _chatsFuture = _repository.fetchPartyChats();
  }

  Future<void> _refresh() async {
    setState(() => _chatsFuture = _repository.fetchPartyChats());
    await _chatsFuture;
  }

  Future<void> _openChat(PartyChatSummary chat) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        partyId: chat.partyId,
        partyTitle: chat.partyTitle,
        isPrivate: chat.isPrivate,
        memberCount: chat.goingCount,
        repository: widget.repository,
      ),
    ));
    // ChatScreen marks the party read on open, so the badge this list is
    // showing is stale by the time we come back.
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Text('Messages',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
              ),
              TabBar(
                indicatorColor: AppColors.purple,
                labelColor: AppColors.text,
                unselectedLabelColor: AppColors.textAlpha(0.45),
                dividerColor: AppColors.hairline,
                labelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                tabs: const [Tab(text: 'Parties'), Tab(text: 'Direct')],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _partyTab(),
                    _DirectChatsTab(repository: _direct),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _partyTab() {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<List<PartyChatSummary>>(
        future: _chatsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final chats = snapshot.data ?? const <PartyChatSummary>[];

          return ListView(
            key: const ValueKey('chat-list-screen'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 6, bottom: 96),
            children: [
              if (snapshot.hasError)
                _notice('Your chats didn’t load.')
              else if (chats.isEmpty)
                _notice(
                  'No chats yet.\nJoin a party and its chat will show up here.',
                )
              else
                for (final chat in chats) _chatRow(chat),
            ],
          );
        },
      ),
    );
  }

  Widget _notice(String text) => _listNotice(text);

  String _stamp(PartyChatSummary chat) => _timeStamp(chat.lastMessageAt);

  Widget _chatRow(PartyChatSummary chat) {
    final tint = chat.isPrivate ? AppColors.private : AppColors.purple;
    final unread = chat.unreadCount > 0;

    final preview = chat.lastMessageBody == null
        ? 'No messages yet'
        : '${chat.lastMessageAuthorUsername ?? ''}: ${chat.lastMessageBody}';

    return GestureDetector(
      onTap: () => _openChat(chat),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [tint.withValues(alpha: 0.1), Colors.transparent]),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 50,
              height: 50,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(color: tint, width: 1.5),
                    ),
                    child: const DiagonalStripePlaceholder(
                        colors: [Color(0xFF1C1622), Color(0xFF151020)]),
                  ),
                  Positioned(
                    bottom: -3,
                    right: -3,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration:
                          BoxDecoration(color: tint, borderRadius: BorderRadius.circular(5)),
                      child: Text('${chat.goingCount}', style: AppTextStyles.mono(size: 7.5)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(chat.partyTitle,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                      ),
                      if (chat.isPrivate) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.lock, size: 11, color: tint),
                      ],
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textAlpha(unread ? 0.8 : 0.6),
                        fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _stamp(chat),
                  style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.4)),
                ),
                if (unread) ...[
                  const SizedBox(height: 4),
                  _unreadPill(chat.unreadLabel, tint),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Widget _listNotice(String text) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.textAlpha(0.5)),
    ),
  );
}

/// HH:mm today, d/m before that. Empty for a conversation with no messages.
String _timeStamp(DateTime? at) {
  if (at == null) return '';

  final now = DateTime.now();
  final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
  if (sameDay) {
    return '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  }
  return '${at.day}/${at.month}';
}

Widget _unreadPill(String label, Color tint) {
  return Container(
    constraints: const BoxConstraints(minWidth: 18),
    height: 18,
    alignment: Alignment.center,
    padding: const EdgeInsets.symmetric(horizontal: 5),
    decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(99)),
    child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
  );
}

/// The Direct tab: every thread someone has written in, most recent activity
/// first, one keyset page at a time.
///
/// Loads on first build rather than with the screen, so a user who never opens
/// the tab never pays for it.
class _DirectChatsTab extends StatefulWidget {
  const _DirectChatsTab({required this.repository});

  final DirectChatRepository repository;

  @override
  State<_DirectChatsTab> createState() => _DirectChatsTabState();
}

class _DirectChatsTabState extends State<_DirectChatsTab>
    with AutomaticKeepAliveClientMixin {
  static const _pageSize = 30;

  final _scroll = ScrollController();
  final List<DirectChatSummary> _threads = [];

  bool _loading = true;
  bool _loadingMore = false;
  bool _reachedEnd = false;
  bool _failed = false;

  /// Keeps the loaded pages when the user flips to Parties and back.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final page = await widget.repository.fetchDirectChats(limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _threads
          ..clear()
          ..addAll(page);
        _reachedEnd = page.length < _pageSize;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _reachedEnd || _threads.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      // The cursor is the last row drawn — a row, never an offset.
      final page = await widget.repository.fetchDirectChats(after: _threads.last, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        final held = {for (final t in _threads) t.threadId};
        _threads.addAll(page.where((t) => !held.contains(t.threadId)));
        _reachedEnd = page.length < _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _open(DirectChatSummary thread) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen.direct(
        threadId: thread.threadId,
        peerUsername: thread.peerUsername,
        peerAvatarUrl: widget.repository.avatarUrl(thread.peerAvatarPath),
        repository: widget.repository,
      ),
    ));
    // The chat marked itself read and may have moved to the top.
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_loading) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        key: const ValueKey('direct-chat-list'),
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 6, bottom: 96),
        children: [
          if (_failed)
            _listNotice('Your messages didn’t load.')
          else if (_threads.isEmpty)
            _listNotice('No direct messages yet.\nOpen someone’s profile and tap Message.')
          else ...[
            for (final thread in _threads) _row(thread),
            if (_loadingMore)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(DirectChatSummary thread) {
    const tint = AppColors.purple;
    final unread = thread.unreadCount > 0;
    final mine = thread.lastMessageAuthorId == widget.repository.currentUserId;

    final preview = thread.lastMessageBody == null
        ? 'No messages'
        : mine
            ? 'You: ${thread.lastMessageBody}'
            : thread.lastMessageBody!;

    const placeholder = DiagonalStripePlaceholder(colors: [Color(0xFF241E3C), Color(0xFF1B1630)]);
    final avatarUrl = widget.repository.avatarUrl(thread.peerAvatarPath);

    return GestureDetector(
      onTap: () => _open(thread),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: tint.withValues(alpha: 0.6), width: 1.5),
              ),
              child: avatarUrl == null
                  ? placeholder
                  : Image.network(avatarUrl, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('@${thread.peerUsername}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textAlpha(unread ? 0.8 : 0.6),
                        fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _timeStamp(thread.lastMessageAt),
                  style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.4)),
                ),
                if (unread) ...[
                  const SizedBox(height: 4),
                  _unreadPill(thread.unreadLabel, tint),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
