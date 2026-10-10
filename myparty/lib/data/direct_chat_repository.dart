import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import 'chat_source.dart';
import 'profile_repository.dart';

/// Every widget-level Supabase call for 1-on-1 direct messages. The DM twin of
/// [ChatRepository], over `direct_threads` / `direct_messages` /
/// `direct_reads` (Phase 33).
///
/// Like its twin it decides nothing. Who may open a thread, who may send in
/// one and what a block does are all answered server-side —
/// `get_or_create_direct_thread`, `can_send_direct_message` and the RLS on
/// all three tables — and every refusal arrives here as the same 42501. The
/// UI turns all of them into one sentence, because the server deliberately
/// makes them indistinguishable: a screen that could tell "blocked" from
/// "their settings say no" would be a block oracle.
class DirectChatRepository {
  DirectChatRepository({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;
  static const _uuid = Uuid();

  /// Lazy for the same reason as [ChatRepository]: a test double overrides
  /// every method and must never touch `Supabase.instance`.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  String? get _uid => _client.auth.currentUser?.id;

  String? get currentUserId => _uid;

  /// The thread with [otherUserId], created if this is the first time.
  ///
  /// Always the same id for the same pair, whichever side asks and however
  /// many times — the pair is a unique key server-side, so there is nothing to
  /// look up here first and nothing to dedupe. Throws on any refusal.
  Future<String> openThread(String otherUserId) async {
    final id = await _client.rpc(
      'get_or_create_direct_thread',
      params: {'p_other_user_id': otherUserId},
    );
    return id as String;
  }

  /// One page of the Direct tab, most recent activity first.
  ///
  /// [after] is the last row of the previous page; its `(activity_at,
  /// thread_id)` is the keyset cursor (CLAUDE.md #5). Threads nobody has
  /// written in yet are not returned.
  Future<List<DirectChatSummary>> fetchDirectChats({
    DirectChatSummary? after,
    int limit = 30,
  }) async {
    final rows = await _client.rpc('get_direct_chats', params: {
      'p_before_activity_at': after?.activityAt.toUtc().toIso8601String(),
      'p_before_id': after?.threadId,
      'p_limit': limit,
    });
    return (rows as List)
        .map((row) => DirectChatSummary.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  /// One page of history, newest first, keyset on [before]'s `(created_at, id)`.
  Future<List<ChatMessage>> fetchMessages(
    String threadId, {
    ChatMessage? before,
    int limit = 30,
  }) async {
    final rows = await _client.rpc('get_direct_messages', params: {
      'p_thread_id': threadId,
      'p_before_created_at': before?.createdAt.toUtc().toIso8601String(),
      'p_before_id': before?.id,
      'p_limit': limit,
    });
    return (rows as List)
        .map((row) => ChatMessage.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  Future<List<ChatMessage>> fetchMessagesSince(String threadId, DateTime since) =>
      fetchChatMessagesSince(
        (before, limit) => fetchMessages(threadId, before: before, limit: limit),
        since,
      );

  /// Sends under a client-generated id, so the optimistic bubble and the
  /// broadcast echo dedupe — `direct_messages` grants INSERT on `id` for that.
  ///
  /// The insert's RETURNING is a read (gotcha 6), and that is fine here: the
  /// SELECT policy shows a member their own lines.
  Future<ChatMessage> sendMessage({
    required String threadId,
    required String body,
  }) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    final row = await _client
        .from('direct_messages')
        .insert({
          'id': _uuid.v4(),
          'thread_id': threadId,
          'author_id': id,
          'body': body,
        })
        .select('id, thread_id, author_id, body, created_at')
        .single();

    return ChatMessage(
      id: row['id'] as String,
      conversationId: row['thread_id'] as String,
      authorId: row['author_id'] as String,
      authorUsername: '',
      body: row['body'] as String,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      status: MessageStatus.sent,
    );
  }

  /// Moves the read watermark to now.
  ///
  /// An RPC, not a PostgREST upsert: `direct_reads` may only UPDATE
  /// `last_read_at`, and an upsert would SET the key columns too and be
  /// refused (gotcha 12 — see `20261010095848`). The server stamps the time
  /// itself and never moves it backwards.
  Future<void> markRead(String threadId) async {
    if (_uid == null) return;
    await _client.rpc('mark_direct_thread_read', params: {'p_thread_id': threadId});
  }

  /// Author-only, checked by `hide_direct_message`.
  Future<void> hideMessage(String messageId, {String? reason}) async {
    await _client.rpc('hide_direct_message', params: {
      'p_message_id': messageId,
      'p_reason': reason,
    });
  }

  /// Joins `dm:{threadId}`. The `realtime.messages` policy admits the two
  /// members and refuses either of them once a block exists.
  ChatChannel subscribe(String threadId) =>
      subscribeChatTopic(_client, 'dm:$threadId');

  /// The peer's avatar for the Direct tab. Delegates to [ProfileRepository]
  /// so the `avatars` bucket stays the single authority on how its objects are
  /// reached.
  String? avatarUrl(String? path) =>
      ProfileRepository(client: _clientOverride).avatarUrl(path);
}
