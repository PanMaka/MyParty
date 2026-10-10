import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

import '../../data/chat_repository.dart';
import '../../data/chat_source.dart';
import '../../data/direct_chat_repository.dart';
import '../../models/chat_message.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/privacy_badge.dart';

/// One conversation: a party's group chat, or a 1-on-1 direct thread.
///
/// Everything the two share — history, keyset paging, optimistic send, echo
/// dedupe, reconnect gap-fill, live retractions — lives here once and talks
/// to a [ChatSource]. The two constructors differ only in which source they
/// build and what the header says.
///
/// Header details are passed in rather than fetched because every caller
/// already holds them (a `PartyChatSummary`, an `RsvpParty`, a `MapPartyPin`,
/// a loaded `Profile` or a `DirectChatSummary`), so a lookup here would be a
/// round trip spent re-reading what the previous screen just rendered.
class ChatScreen extends StatefulWidget {
  /// A party's group chat. [partyId] is a real `parties.id`.
  const ChatScreen({
    super.key,
    required String partyId,
    required String partyTitle,
    this.isPrivate = false,
    this.memberCount,
    ChatRepository? repository,
  })  : conversationId = partyId,
        title = partyTitle,
        partyRepository = repository,
        directRepository = null,
        peerAvatarUrl = null,
        isDirect = false;

  /// A 1-on-1 thread. [threadId] comes from
  /// `DirectChatRepository.openThread` or a `DirectChatSummary`.
  const ChatScreen.direct({
    super.key,
    required String threadId,
    required String peerUsername,
    this.peerAvatarUrl,
    DirectChatRepository? repository,
  })  : conversationId = threadId,
        title = '@$peerUsername',
        isPrivate = false,
        memberCount = null,
        partyRepository = null,
        directRepository = repository,
        isDirect = true;

  /// The party id, or the thread id.
  final String conversationId;
  final String title;
  final bool isPrivate;
  final int? memberCount;
  final String? peerAvatarUrl;
  final bool isDirect;

  /// Injectable for tests; production callers let them default.
  final ChatRepository? partyRepository;
  final DirectChatRepository? directRepository;

  ChatSource _buildSource() => isDirect
      ? DirectChatSource(directRepository ?? DirectChatRepository(), conversationId)
      : PartyChatSource(partyRepository ?? ChatRepository(), conversationId);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatSource _source = widget._buildSource();

  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  /// Oldest first — the order the list renders in. History arrives
  /// newest-first from the keyset RPC and is reversed on the way in.
  final List<ChatMessage> _messages = [];
  final Set<String> _seenIds = {};

  ChatChannel? _channel;
  StreamSubscription<ChatMessage>? _messageSub;
  StreamSubscription<String>? _hiddenSub;
  StreamSubscription<RealtimeSubscribeStatus>? _statusSub;

  bool _loading = true;
  bool _loadingMore = false;
  bool _reachedStart = false;
  bool _hasSubscribedOnce = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _loadInitialHistory();
    _connect();
  }

  Future<void> _loadInitialHistory() async {
    try {
      final page = await _source.fetchMessages();
      if (!mounted) return;
      setState(() {
        _ingest(page);
        _reachedStart = page.length < 30;
        _loading = false;
      });
      _jumpToBottom();
      unawaited(_source.markRead());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'The chat didn’t load.';
      });
    }
  }

  void _connect() {
    final channel = _source.subscribe();
    _channel = channel;

    _messageSub = channel.messages.listen((message) {
      if (!mounted) return;
      final wasAtBottom = _isAtBottom();
      setState(() => _ingest([message]));
      if (wasAtBottom) _jumpToBottom();
      unawaited(_source.markRead());
    });

    _hiddenSub = channel.hiddenMessageIds.listen((id) {
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((m) => m.id == id);
        _seenIds.remove(id);
      });
    });

    _statusSub = channel.status.listen((state) {
      if (state != RealtimeSubscribeStatus.subscribed) return;

      // The FIRST subscribe needs no gap-fill: history was just fetched.
      // Every subsequent one does. Broadcast has no replay, so anything sent
      // while the socket was down never arrives on its own — reconnecting is
      // not "resume listening", it is "ask what I missed".
      if (_hasSubscribedOnce) {
        unawaited(_fillGap());
      }
      _hasSubscribedOnce = true;
    });
  }

  /// Closes the hole a dropped connection left behind.
  Future<void> _fillGap() async {
    final newest = _messages.isEmpty ? null : _messages.last.createdAt;
    try {
      final missed = newest == null
          ? await _source.fetchMessages()
          : await _source.fetchMessagesSince(newest);
      if (!mounted || missed.isEmpty) return;

      final wasAtBottom = _isAtBottom();
      setState(() => _ingest(missed));
      if (wasAtBottom) _jumpToBottom();
      unawaited(_source.markRead());
    } catch (_) {
      // A failed gap-fill is not worth interrupting the user over: the next
      // reconnect tries again, and the messages already on screen are still
      // correct — just possibly incomplete.
    }
  }

  /// Merges rows in, keeping the list sorted and free of duplicates.
  ///
  /// Deduping by id is what makes the optimistic send work: the pending
  /// bubble is already on screen under the id the row was stored with, so its
  /// own broadcast echo replaces it rather than appearing twice. It also
  /// covers the honest overlap between a gap-fill page and messages that
  /// arrived live while the fetch was in flight.
  void _ingest(Iterable<ChatMessage> incoming) {
    for (final message in incoming) {
      final existingIndex = _messages.indexWhere((m) => m.id == message.id);
      if (existingIndex >= 0) {
        // A confirmed row always wins over a local pending one.
        if (message.status == MessageStatus.sent) {
          _messages[existingIndex] = message;
        }
        continue;
      }
      _messages.add(message);
      _seenIds.add(message.id);
    }
    _messages.sort((a, b) => a.compareTo(b));
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    // Older messages live at the top, so paging happens on scroll-UP.
    if (_scrollController.position.pixels <= 200) {
      unawaited(_loadOlder());
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingMore || _reachedStart || _messages.isEmpty) return;
    setState(() => _loadingMore = true);

    try {
      // The keyset cursor is the OLDEST message held — a row, never an
      // offset (CLAUDE.md #5).
      final page = await _source.fetchMessages(before: _messages.first);
      if (!mounted) return;
      setState(() {
        _ingest(page);
        _reachedStart = page.length < 30;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final uid = _source.currentUserId;
    if (uid == null) return;

    _controller.clear();

    // Optimistic: render before the insert round-trips. The id is generated
    // inside sendMessage, so this local row carries a temporary one and is
    // swapped for the stored row when the insert returns.
    final pendingId = 'pending-${DateTime.now().microsecondsSinceEpoch}';
    final pending = ChatMessage(
      id: pendingId,
      conversationId: widget.conversationId,
      authorId: uid,
      authorUsername: '',
      body: text,
      createdAt: DateTime.now().toUtc(),
      status: MessageStatus.sending,
    );

    setState(() => _ingest([pending]));
    _jumpToBottom();

    try {
      final stored = await _source.sendMessage(text);
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((m) => m.id == pendingId);
        _seenIds.remove(pendingId);
        _ingest([stored]);
      });
    } catch (_) {
      if (!mounted) return;
      // The bubble stays, marked failed. A message that silently disappears
      // after you hit send is worse than one that admits it did not go —
      // and the insert is rejected for real reasons the user can act on:
      // the rate limit, or having been removed from the party.
      setState(() {
        final i = _messages.indexWhere((m) => m.id == pendingId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(status: MessageStatus.failed);
        }
      });
    }
  }

  Future<void> _retry(ChatMessage failed) async {
    setState(() {
      _messages.removeWhere((m) => m.id == failed.id);
      _seenIds.remove(failed.id);
    });
    _controller.text = failed.body;
    await _send();
  }

  bool _isAtBottom() {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.pixels >= position.maxScrollExtent - 120;
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _hiddenSub?.cancel();
    _statusSub?.cancel();
    unawaited(_channel?.dispose() ?? Future.value());
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _header(context),
            Expanded(child: _body()),
            _inputBar(),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.6))),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _loadInitialHistory();
                },
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Nobody has written anything yet. Say something.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.5)),
          ),
        ),
      );
    }

    return ListView.separated(
      key: const ValueKey('chat-list'),
      controller: _scrollController,
      padding: const EdgeInsets.all(14),
      itemCount: _messages.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, i) {
        if (i == 0) {
          return Center(
            child: _loadingMore
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : Text(
                    _reachedStart ? 'START OF CHAT' : '…',
                    style: AppTextStyles.mono(size: 9.5, color: AppColors.textAlpha(0.3)),
                  ),
          );
        }
        return _bubble(_messages[i - 1]);
      },
    );
  }

  Widget _header(BuildContext context) {
    final tint = widget.isPrivate ? AppColors.private : AppColors.purple;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tint.withValues(alpha: 0.12), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.chevron_left, size: 26),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 8),
          _headerAvatar(tint),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(widget.title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                    ),
                    // A DM has no privacy tier to badge: it is always exactly
                    // two people.
                    if (!widget.isDirect) ...[
                      const SizedBox(width: 6),
                      PrivacyBadge(isPrivate: widget.isPrivate),
                    ],
                  ],
                ),
                if (widget.memberCount case final count?)
                  Text(
                    widget.isPrivate
                        ? '$count ${count == 1 ? 'member' : 'members'} · invited only'
                        : '$count ${count == 1 ? 'member' : 'members'}',
                    style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.5)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A party is a rounded square, a person is a circle — the same shapes the
  /// chat list and the profile header use.
  Widget _headerAvatar(Color tint) {
    const placeholder = DiagonalStripePlaceholder(colors: [Color(0xFF1C1622), Color(0xFF151020)]);
    final url = widget.peerAvatarUrl;

    return Container(
      width: 40,
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: widget.isDirect ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: widget.isDirect ? null : BorderRadius.circular(12),
        border: Border.all(color: tint, width: 1.5),
      ),
      child: url == null
          ? placeholder
          : Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
    );
  }

  Widget _bubble(ChatMessage msg) {
    final mine = msg.authorId == _source.currentUserId;

    if (mine) {
      final failed = msg.status == MessageStatus.failed;
      return Align(
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Opacity(
              opacity: msg.status == MessageStatus.sending ? 0.55 : 1,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 280),
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                decoration: BoxDecoration(
                  gradient: failed ? null : AppColors.purpleGradient,
                  color: failed ? AppColors.pink.withValues(alpha: 0.18) : null,
                  border: failed ? Border.all(color: AppColors.pink.withValues(alpha: 0.5)) : null,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(14),
                    topRight: Radius.circular(14),
                    bottomLeft: Radius.circular(14),
                    bottomRight: Radius.circular(4),
                  ),
                ),
                child: Text(msg.body, style: const TextStyle(fontSize: 13, height: 1.45)),
              ),
            ),
            if (failed)
              TextButton(
                onPressed: () => _retry(msg),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text('Not sent. Try again.',
                    style: TextStyle(fontSize: 10.5, color: AppColors.pinkLight)),
              ),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [Color(0xFF232C40), Color(0xFF1A2030)]),
          ),
        ),
        const SizedBox(width: 9),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(msg.authorUsername,
                  style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.45))),
              const SizedBox(height: 3),
              GestureDetector(
                onLongPress: _source.canHideOthersMessages ? () => _showMessageActions(msg) : null,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 260),
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      topRight: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                      bottomLeft: Radius.circular(4),
                    ),
                  ),
                  child: Text(msg.body, style: const TextStyle(fontSize: 13, height: 1.45)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// `hide_message` re-checks authorship and hosting server-side, so this
  /// offers the action to everyone and lets the RPC refuse — the alternative
  /// is teaching the client who the host is, which is a second copy of a rule
  /// the server already owns.
  void _showMessageActions(ChatMessage msg) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.sheet,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined, size: 20),
              title: const Text('Hide message', style: TextStyle(fontSize: 13.5)),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await _source.hideMessage(msg.id);
                } catch (_) {
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('Failed to hide message. Try again.'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              onSubmitted: (_) => _send(),
              style: const TextStyle(fontSize: 13),
              maxLength: 2000,
              buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
              decoration: InputDecoration(
                hintText: widget.isDirect ? 'Message…' : 'Party message…',
                hintStyle: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.42)),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.06),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(99),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _send,
            child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle),
              child: const Icon(Icons.arrow_upward, size: 16, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
