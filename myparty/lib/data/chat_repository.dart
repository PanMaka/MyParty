import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/party_message.dart';

/// A live subscription to one party's chat topic.
///
/// Wraps a `RealtimeChannel` in plain streams so [ChatScreen] never touches
/// the realtime API directly, and so a test can hand the screen an instance
/// built from ordinary `StreamController`s.
class PartyChatChannel {
  PartyChatChannel({
    required this.messages,
    required this.hiddenMessageIds,
    required this.status,
    required this.dispose,
  });

  /// `new_message` broadcasts.
  final Stream<PartyMessage> messages;

  /// `message_hidden` broadcasts — a moderation retraction carrying only the
  /// id. Without this, a host takes a message down and every phone with the
  /// chat already open keeps rendering it until the screen is reopened.
  final Stream<String> hiddenMessageIds;

  /// Every subscribe/disconnect transition. [ChatScreen] listens for a
  /// *re*-subscribe to know it needs to close the gap that opened while the
  /// socket was down.
  final Stream<RealtimeSubscribeStatus> status;

  /// Closes the streams and leaves the channel. A field rather than a method
  /// so a test can supply its own teardown without subclassing.
  final Future<void> Function() dispose;
}

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
  Future<List<PartyMessage>> fetchMessages(
    String partyId, {
    PartyMessage? before,
    int limit = 30,
  }) async {
    final rows = await _client.rpc('get_messages', params: {
      'p_party_id': partyId,
      'p_before_created_at': before?.createdAt.toUtc().toIso8601String(),
      'p_before_id': before?.id,
      'p_limit': limit,
    });

    return (rows as List)
        .map((row) => PartyMessage.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  /// Everything that arrived after [since] — the reconnect gap-fill.
  ///
  /// Broadcast has no replay, so anything sent while the socket was down is
  /// simply gone from the client's point of view. Reconnecting therefore
  /// cannot mean "resume listening"; it has to mean "ask what I missed".
  /// Pages backwards from the newest until it reaches [since], which is one
  /// round trip for a normal blip and stays bounded for a long outage — at
  /// which point the user is better served by the screen reloading anyway.
  Future<List<PartyMessage>> fetchMessagesSince(
    String partyId,
    DateTime since, {
    int maxPages = 5,
    int pageSize = 50,
  }) async {
    final gathered = <PartyMessage>[];
    PartyMessage? cursor;

    for (var page = 0; page < maxPages; page++) {
      final rows = await fetchMessages(partyId, before: cursor, limit: pageSize);
      if (rows.isEmpty) break;

      gathered.addAll(rows.where((m) => m.createdAt.isAfter(since)));

      // The page is newest-first, so its last row is the oldest one in it.
      // Once that is at or before the watermark, everything older is already
      // held and there is nothing left to close.
      final oldest = rows.last;
      if (!oldest.createdAt.isAfter(since)) break;
      if (rows.length < pageSize) break;
      cursor = oldest;
    }

    return gathered;
  }

  /// Sends a message under a client-generated id.
  ///
  /// The id is generated here, not by the server, so the caller can render
  /// the bubble immediately and still recognise its own broadcast echo when
  /// it comes back — `messages` grants INSERT on `id` for exactly that.
  /// Returns the message as stored; throws if the insert is rejected, which
  /// is how "you are not in this chat" and "you are sending too fast" both
  /// reach the UI (both are `42501` from the policy and the rate-limit
  /// trigger respectively).
  Future<PartyMessage> sendMessage({
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

    return PartyMessage(
      id: row['id'] as String,
      partyId: row['party_id'] as String,
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
  Future<void> markRead(String partyId) async {
    final id = _uid;
    if (id == null) return;

    await _client.from('party_reads').upsert(
      {
        'party_id': partyId,
        'user_id': id,
        'last_read_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'party_id,user_id',
    );
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

  /// Joins the party's broadcast topic.
  ///
  /// `private: true` is load bearing: it makes the client present its auth
  /// token on the channel so the RLS policy on `realtime.messages` runs. On a
  /// public channel the policy never evaluates and the join is simply
  /// unauthorized — which looks exactly like a party with no traffic, so
  /// getting this wrong fails silently rather than loudly.
  ///
  /// Note there is no send path here at all. Messages are sent by INSERT into
  /// `messages` and arrive back through this channel via the database
  /// trigger; the client never broadcasts. `realtime.messages` has no INSERT
  /// policy precisely so that stays true.
  PartyChatChannel subscribe(String partyId) {
    final messages = StreamController<PartyMessage>.broadcast();
    final hidden = StreamController<String>.broadcast();
    final status = StreamController<RealtimeSubscribeStatus>.broadcast();

    final channel = _client.channel(
      'party:$partyId',
      opts: const RealtimeChannelConfig(private: true),
    );

    channel
        .onBroadcast(
          event: 'new_message',
          callback: (payload) {
            if (messages.isClosed) return;
            messages.add(PartyMessage.fromBroadcast(payload));
          },
        )
        .onBroadcast(
          event: 'message_hidden',
          callback: (payload) {
            if (hidden.isClosed) return;
            final id = payload['id'] as String?;
            if (id != null) hidden.add(id);
          },
        )
        .subscribe((state, error) {
          if (!status.isClosed) status.add(state);
        });

    return PartyChatChannel(
      messages: messages.stream,
      hiddenMessageIds: hidden.stream,
      status: status.stream,
      dispose: () async {
        await messages.close();
        await hidden.close();
        await status.close();
        await _client.removeChannel(channel);
      },
    );
  }
}
