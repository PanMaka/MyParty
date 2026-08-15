import 'package:flutter/material.dart';

import '../../data/chat_repository.dart';
import '../../models/party_message.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import 'chat_screen.dart';

/// The chat list, backed by `public.get_party_chats`.
///
/// Replaces the two hardcoded `mpParties` rows this screen used to render.
/// The list is exactly the set of parties the user participates in — host,
/// invited, or RSVP'd — because that is what `can_chat_in_party` says, and
/// the RPC applies it rather than this screen filtering anything.
class MessagesScreen extends StatefulWidget {
  /// Injectable for tests; production callers let it default.
  final ChatRepository? repository;

  const MessagesScreen({super.key, this.repository});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  late final ChatRepository _repository = widget.repository ?? ChatRepository();
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
      ),
    ));
    // ChatScreen marks the party read on open, so the badge this list is
    // showing is stale by the time we come back.
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
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
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Text('Μηνύματα',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                  ),
                  if (snapshot.hasError)
                    _notice('Δεν φόρτωσαν οι συζητήσεις.')
                  else if (chats.isEmpty)
                    _notice(
                      'Καμία συζήτηση ακόμα.\nΜπες σε ένα πάρτι και θα εμφανιστεί εδώ.',
                    )
                  else
                    for (final chat in chats) _chatRow(chat),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _notice(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.textAlpha(0.5)),
      ),
    );
  }

  Widget _chatRow(PartyChatSummary chat) {
    final tint = chat.isPrivate ? AppColors.pink : AppColors.purple;
    final unread = chat.unreadCount > 0;

    final preview = chat.lastMessageBody == null
        ? 'Κανένα μήνυμα ακόμα'
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
                  Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration:
                        BoxDecoration(color: tint, borderRadius: BorderRadius.circular(99)),
                    child: Text(chat.unreadLabel,
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _stamp(PartyChatSummary chat) {
    final at = chat.lastMessageAt;
    if (at == null) return '';

    final now = DateTime.now();
    final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
    if (sameDay) {
      return '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    }
    return '${at.day}/${at.month}';
  }
}
