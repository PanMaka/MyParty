import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import 'chat_source.dart';

/// Every widget-level Supabase call for group chat goes through here —
/// screens never call `Supabase.instance.client` directly. Mirrors
/// [FeedRepository] and [PartyRepository].
///
/// Nothing here re-checks visibility. `messages` defers to
/// `can_chat_in_party`, and the broadcast topic defers to the same helper via
/// the RLS policy on `realtime.messages`, so a party the user is not a
/// participant in has no rows to return and no channel to join. A
/// client-side filter would be a second copy of that rule and would drift.
class ChatRepository {
  ChatRepository({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;
  static const _uuid = Uuid();

  /// Resolved lazily for the same reason [FeedRepository] does it: a test
  /// double subclasses this and overrides every method, and constructing a
  /// real client just to discard it starts a realtime heartbeat that
  /// `pumpAndSettle` then blocks on.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  String? get _uid => _client.auth.currentUser?.id;

  /// Who is signed in. Exposed because the bubbles need it to decide which
  /// side of the screen a message belongs on, and reaching into
  /// `Supabase.instance` from a widget would break the rule this class exists
  /// to enforce — and make the widget untestable, since there is no
  /// initialized client under `flutter test`.
  String? get currentUserId => _uid;

  /// The chat list: parties the user actually participates in, newest
  /// conversation first, with unread badges.
  Future<List<PartyChatSummary>> fetchPartyChats() async {
    final rows = await _client.rpc('get_party_chats');
    return (rows as List)
        .map((row) => PartyChatSummary.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  /// One page of history, newest first.
  ///
  /// [before] is the oldest message of the previous page — its
  /// `(created_at, id)` is the keyset cursor. Both halves travel together
  /// because several people hitting send in the same instant share a
  /// timestamp, and the id is then the only thing producing a total order.
  /// Never an offset (CLAUDE.md #5).
  Future<List<ChatMessage>> fetchMessages(
    String partyId, {
    ChatMessage? before,
    int limit = 30,
  }) async {
    final rows = await _client.rpc('get_messages', params: {
      'p_party_id': partyId,
      'p_before_created_at': before?.createdAt.toUtc().toIso8601String(),
      'p_before_id': before?.id,
      'p_limit': limit,
    });

    return (rows as List)
        .map((row) => ChatMessage.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  /// Everything that arrived after [since] — the reconnect gap-fill. See
  /// [fetchChatMessagesSince].
  Future<List<ChatMessage>> fetchMessagesSince(String partyId, DateTime since) =>
      fetchChatMessagesSince(
        (before, limit) => fetchMessages(partyId, before: before, limit: limit),
        since,
      );

  /// Sends a message under a client-generated id.
  ///
  /// The id is generated here, not by the server, so the caller can render
  /// the bubble immediately and still recognise its own broadcast echo when
  /// it comes back — `messages` grants INSERT on `id` for exactly that.
  /// Returns the message as stored; throws if the insert is rejected, which
  /// is how "you are not in this chat" and "you are sending too fast" both
  /// reach the UI (both are `42501` from the policy and the rate-limit
  /// trigger respectively).
  Future<ChatMessage> sendMessage({
    required String partyId,
    required String body,
  }) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    final messageId = _uuid.v4();

    final row = await _client
        .from('messages')
        .insert({
          'id': messageId,
          'party_id': partyId,
          'author_id': id,
          'body': body,
        })
        .select('id, party_id, author_id, body, created_at')
        .single();

    return ChatMessage(
      id: row['id'] as String,
      conversationId: row['party_id'] as String,
      authorId: row['author_id'] as String,
      // Own messages render without an author label, so there is nothing to
      // look up here — and a join to fetch our own username would be a round
      // trip spent on something the bubble never draws.
      authorUsername: '',
      body: row['body'] as String,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      status: MessageStatus.sent,
    );
  }

  /// Moves the read watermark for this party to now.
  ///
  /// Fire-and-forget from the UI's point of view: the server clamps the value
  /// to its own clock and refuses to move it backwards, so a stale or racing
  /// call from a second device is harmless and needs no coordination here.
  ///
  /// An RPC, not a PostgREST upsert. `party_reads` may only UPDATE
  /// `last_read_at`, and an upsert SETs every key in the body, so it was
  /// refused with 403 on every call — and swallowed, which left every badge
  /// stuck (`20261010101036`, gotcha 12).
  Future<void> markRead(String partyId) async {
    if (_uid == null) return;
    await _client.rpc('mark_party_read', params: {'p_party_id': partyId});
  }

  /// Soft delete, never a hard one (CLAUDE.md #7). An RPC rather than a PATCH
  /// because `messages` carries no update grant at all: on UPDATE Postgres
  /// applies the SELECT policy to the *new* row, and the new row is hidden,
  /// so a client-side soft-delete is structurally impossible.
  /// `hide_message` re-checks authorship/hosting server-side.
  Future<void> hideMessage(String messageId, {String? reason}) async {
    await _client.rpc('hide_message', params: {
      'p_message_id': messageId,
      'p_reason': reason,
    });
  }

  /// Joins the party's broadcast topic. The channel mechanics — and why it
  /// must be private, and why there is no send path — are in
  /// [subscribeChatTopic], shared with direct messages.
  ChatChannel subscribe(String partyId) =>
      subscribeChatTopic(_client, 'party:$partyId');
}
