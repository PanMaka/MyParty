import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

import '../../data/chat_repository.dart';
import '../../data/chat_source.dart';
import '../../data/direct_chat_repository.dart';
import '../../models/chat_message.dart';
import '../../state/data_changes.dart';
import '../../state/live_refresh.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/mp_bottom_nav.dart' show MpTab;
import '../widgets/user_link.dart';
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
///
/// **Both tabs stay live while on screen.** Your own reads, sends and hides
/// arrive as [DataChange]s from the chat repositories, wherever the chat was
/// opened from; other people's lines arrive over the conversations' own
/// broadcast topics — the Parties tab holds the `party:{uuid}` of each row it
/// shows (see [ChatListWatcher]), the Direct tab holds the viewer's one
/// `inbox:{uuid}` — and drops them when the Messages tab is hidden. A topic only
/// says "something happened": the tab refetches, debounced by [_settle], so a
/// burst of lines is one round trip and the counts are always the server's.
const Duration _settle = Duration(milliseconds: 750);
class MessagesScreen extends StatefulWidget {
  /// Injectable for tests; production callers let them default.
  final ChatRepository? repository;
  final DirectChatRepository? directRepository;

  const MessagesScreen({super.key, this.repository, this.directRepository});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> with LiveRefresh<MessagesScreen> {
  late final ChatRepository _repository = widget.repository ?? ChatRepository();
  late final DirectChatRepository _direct = widget.directRepository ?? DirectChatRepository();
  late Future<List<PartyChatSummary>> _chatsFuture;

  /// The last list that loaded — what the topics are held for, and what a
  /// read is patched into before the refetch confirms it.
  List<PartyChatSummary> _chats = const [];

  late final ChatListWatcher _watcher = ChatListWatcher(
    subscribe: _repository.subscribe,
    onActivity: _soon,
  );
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _chatsFuture = _fetch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _watcher.clear();
    super.dispose();
  }

  Future<List<PartyChatSummary>> _fetch() {
    final future = _repository.fetchPartyChats();
    future.then((chats) {
      if (!mounted) return;
      _chats = chats;
      if (isLiveVisible) _watcher.watch(chats.map((c) => c.partyId));
    }, onError: (_) {});
    return future;
  }

  Future<void> _refresh() async {
    // A block body: an arrow would return the Future from the closure, which
    // setState asserts against — the pull-to-refresh here threw in debug
    // builds from the day it was added.
    setState(() {
      _chatsFuture = _fetch();
    });
    try {
      await _chatsFuture;
    } catch (_) {
      // Rendered by the FutureBuilder; the pull spinner only needs it settled.
    }
  }

  @override
  MpTab? get liveTab => MpTab.messages;

  @override
  Future<void> liveRefresh() => _refresh();

  @override
  void onLiveVisibilityChanged(bool visible) {
    if (visible) {
      _watcher.watch(_chats.map((c) => c.partyId));
    } else {
      _debounce?.cancel();
      _watcher.clear();
    }
  }

  @override
  void onDataChange(DataChange change) {
    switch (change) {
      // The badge clears now; the refetch confirms it and picks up anything
      // said since.
      case ConversationRead(:final conversationId, direct: false):
        if (_chats.any((c) => c.partyId == conversationId)) {
          setState(() {
            _chats = [for (final c in _chats) c.partyId == conversationId ? c.read() : c];
          });
        }
        _soon();
      case MessageSent(direct: false) || MessageHidden(direct: false) || BlockChanged():
        _soon();
      default:
        break;
    }
  }

  /// A refetch, debounced, or deferred to the next time the tab is shown.
  void _soon() {
    if (!mounted) return;
    if (!isLiveVisible) {
      refreshWhenVisible();
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(_settle, () {
      if (mounted) refreshWhenVisible();
    });
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
    // No refresh on the way back: ChatScreen marks the party read, and the
    // repository announces that the moment it lands — which also covers a
    // chat opened from the map, a party sheet or the host wizard, none of
    // which come back through here.
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
          // A refetch keeps the rows it is replacing on screen.
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          // [_chats], not snapshot.data: it is the same list once a fetch
          // lands (it is assigned before the builder hears), and unlike the
          // snapshot it also carries a read patched in this frame.
          final chats = snapshot.hasData ? _chats : const <PartyChatSummary>[];

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
    with AutomaticKeepAliveClientMixin, LiveRefresh<_DirectChatsTab> {
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

  /// The viewer's `inbox:{uuid}`, held while the tab is on screen. One topic
  /// for every thread — including one somebody opens with you after this list
  /// loaded, which no per-thread `dm:{uuid}` subscription could cover.
  InboxChannel? _inbox;
  final List<StreamSubscription<Object?>> _inboxSubs = [];
  Timer? _debounce;

  void _holdInbox() {
    if (_inbox != null) return;
    final inbox = widget.repository.subscribeInbox();
    if (inbox == null) return;
    _inbox = inbox;
    // The first `subscribed` is the join; a later one is a reconnect, and
    // broadcast has no replay.
    var joined = false;
    _inboxSubs
      ..add(inbox.activity.listen((_) => _soon()))
      ..add(inbox.status.listen((state) {
        if (state != RealtimeSubscribeStatus.subscribed) return;
        if (joined) _soon();
        joined = true;
      }));
  }

  void _dropInbox() {
    for (final sub in _inboxSubs) {
      sub.cancel();
    }
    _inboxSubs.clear();
    final inbox = _inbox;
    _inbox = null;
    if (inbox != null) unawaited(inbox.dispose());
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    if (isLiveVisible) _holdInbox();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _dropInbox();
    _scroll.dispose();
    super.dispose();
  }

  @override
  MpTab? get liveTab => MpTab.messages;

  @override
  Future<void> liveRefresh() => _reload();

  @override
  void onLiveVisibilityChanged(bool visible) {
    if (visible) {
      _holdInbox();
    } else {
      _debounce?.cancel();
      _dropInbox();
    }
  }

  @override
  void onDataChange(DataChange change) {
    switch (change) {
      case ConversationRead(:final conversationId, direct: true):
        final at = _threads.indexWhere((t) => t.threadId == conversationId);
        if (at >= 0) setState(() => _threads[at] = _threads[at].read());
        _soon();
      case MessageSent(direct: true) || MessageHidden(direct: true) || BlockChanged():
        _soon();
      default:
        break;
    }
  }

  void _soon() {
    if (!mounted) return;
    if (!isLiveVisible) {
      refreshWhenVisible();
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(_settle, () {
      if (mounted) refreshWhenVisible();
    });
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
        // A failed refetch keeps the threads already on screen; only a list
        // with nothing to show says it did not load.
        _failed = _threads.isEmpty;
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
        peerId: thread.peerId,
        peerAvatarUrl: widget.repository.avatarUrl(thread.peerAvatarPath),
        repository: widget.repository,
      ),
    ));
    // No reload on the way back: the read and anything sent are announced by
    // the repository as they land (see [onDataChange]).
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
            // The avatar and the handle open the peer's profile; the rest of
            // the row still opens the thread. The avatar is the full-size
            // target; the handle is a link exactly its own size, so that no
            // part of the preview line under it stops opening the thread.
            UserLink(
              userId: thread.peerId,
              username: thread.peerUsername,
              child: Container(
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
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UserLink(
                    userId: thread.peerId,
                    username: thread.peerUsername,
                    minTapSize: 0,
                    child: Text('@${thread.peerUsername}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
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
