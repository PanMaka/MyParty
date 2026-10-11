import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/chat_message.dart';
import 'chat_repository.dart';
import 'direct_chat_repository.dart';

/// A live subscription to one conversation's broadcast topic — `party:{uuid}`
/// or `dm:{uuid}`.
///
/// Wraps a `RealtimeChannel` in plain streams so [ChatScreen] never touches
/// the realtime API directly, and so a test can hand the screen an instance
/// built from ordinary `StreamController`s.
class ChatChannel {
  ChatChannel({
    required this.messages,
    required this.hiddenMessageIds,
    required this.status,
    required this.dispose,
  });

  /// `new_message` broadcasts.
  final Stream<ChatMessage> messages;

  /// `message_hidden` broadcasts — a retraction carrying only the id. Without
  /// this, a message is taken down and every phone with the chat already open
  /// keeps rendering it until the screen is reopened.
  final Stream<String> hiddenMessageIds;

  /// Every subscribe/disconnect transition. [ChatScreen] listens for a
  /// *re*-subscribe to know it needs to close the gap that opened while the
  /// socket was down.
  final Stream<RealtimeSubscribeStatus> status;

  /// Closes the streams and leaves the channel. A field rather than a method
  /// so a test can supply its own teardown without subclassing.
  final Future<void> Function() dispose;
}

/// Joins [topic] as a PRIVATE channel and adapts it to a [ChatChannel].
///
/// `private: true` is load bearing: it makes the client present its auth
/// token on the channel so the RLS policy on `realtime.messages` runs. On a
/// public channel the policy never evaluates and the join is simply
/// unauthorized — which looks exactly like a conversation with no traffic, so
/// getting this wrong fails silently rather than loudly.
///
/// There is no send path here. Messages are sent by INSERT and arrive back
/// through this channel via the database trigger; the client never
/// broadcasts, and `realtime.messages` has no INSERT policy so that stays true.
///
/// **One channel per topic, shared.** The Messages list watches the topics of
/// the chats it shows while an open [ChatScreen] watches its own, and those
/// overlap. `client.channel()` makes a new channel every call, and a second
/// join of the same topic on one socket makes the server close the first —
/// so two holders of `party:{id}` would cut each other off. Holders share the
/// channel instead, and it is left when the last one disposes.
ChatChannel subscribeChatTopic(SupabaseClient client, String topic) {
  final key = '${identityHashCode(client)}|$topic';
  final shared = _sharedTopics[key] ??= _SharedTopic.open(client, topic);
  shared.holders += 1;

  // Per holder, and replaying the last status: [ChatScreen] treats every
  // `subscribed` after its first as a reconnect that needs a gap-fill, so a
  // holder that joins an already-subscribed channel has to see that first
  // `subscribed` too, exactly as if it had joined on its own.
  final status = StreamController<RealtimeSubscribeStatus>.broadcast();
  final forward = shared.status.stream.listen(status.add);
  final last = shared.lastStatus;
  if (last != null) {
    scheduleMicrotask(() {
      if (!status.isClosed) status.add(last);
    });
  }

  var disposed = false;
  return ChatChannel(
    messages: shared.messages.stream,
    hiddenMessageIds: shared.hidden.stream,
    status: status.stream,
    dispose: () async {
      if (disposed) return;
      disposed = true;
      await forward.cancel();
      await status.close();
      shared.holders -= 1;
      if (shared.holders == 0) {
        _sharedTopics.remove(key);
        await shared.close(client);
      }
    },
  );
}

final Map<String, _SharedTopic> _sharedTopics = {};

class _SharedTopic {
  _SharedTopic._(this.channel);

  factory _SharedTopic.open(SupabaseClient client, String topic) {
    final shared = _SharedTopic._(client.channel(
      topic,
      opts: const RealtimeChannelConfig(private: true),
    ));

    shared.channel
        .onBroadcast(
          event: 'new_message',
          callback: (payload) {
            if (shared.messages.isClosed) return;
            shared.messages.add(ChatMessage.fromBroadcast(payload));
          },
        )
        .onBroadcast(
          event: 'message_hidden',
          callback: (payload) {
            if (shared.hidden.isClosed) return;
            final id = payload['id'] as String?;
            if (id != null) shared.hidden.add(id);
          },
        )
        .subscribe((state, error) {
          shared.lastStatus = state;
          if (!shared.status.isClosed) shared.status.add(state);
        });

    return shared;
  }

  final RealtimeChannel channel;
  final messages = StreamController<ChatMessage>.broadcast();
  final hidden = StreamController<String>.broadcast();
  final status = StreamController<RealtimeSubscribeStatus>.broadcast();
  RealtimeSubscribeStatus? lastStatus;
  int holders = 0;

  Future<void> close(SupabaseClient client) async {
    await messages.close();
    await hidden.close();
    await status.close();
    await client.removeChannel(channel);
  }
}

/// Keeps a chat list's rows live: holds the broadcast topic of each listed
/// conversation and reports any traffic on any of them through [onActivity].
///
/// Traffic, not content. The list does not render from the payload — it
/// refetches, so the unread count stays the server's and a blocked author's
/// line is filtered by the SELECT policy rather than trusted from a broadcast.
///
/// Capped at [limit] topics, the most recent first: the realtime server limits
/// channels per connection, and a conversation far down the list is one the
/// tab-focus and resume refetches cover well enough.
class ChatListWatcher {
  ChatListWatcher({required this.subscribe, required this.onActivity, this.limit = 25});

  final ChatChannel Function(String conversationId) subscribe;
  final void Function() onActivity;
  final int limit;

  final Map<String, ({ChatChannel channel, List<StreamSubscription<Object?>> subs})> _held = {};

  /// The conversations currently held.
  Set<String> get watching => _held.keys.toSet();

  /// Holds exactly the first [limit] of [conversationIds], leaving the rest.
  void watch(Iterable<String> conversationIds) {
    final wanted = conversationIds.take(limit).toSet();
    for (final id in _held.keys.where((id) => !wanted.contains(id)).toList()) {
      _drop(id);
    }
    for (final id in wanted) {
      if (_held.containsKey(id)) continue;
      final channel = subscribe(id);
      // The first `subscribed` is the join; any later one is a reconnect, and
      // broadcast has no replay, so whatever was said meanwhile is activity.
      var joined = false;
      _held[id] = (
        channel: channel,
        subs: [
          channel.messages.listen((_) => onActivity()),
          channel.hiddenMessageIds.listen((_) => onActivity()),
          channel.status.listen((state) {
            if (state != RealtimeSubscribeStatus.subscribed) return;
            if (joined) onActivity();
            joined = true;
          }),
        ],
      );
    }
  }

  /// Leaves every topic.
  void clear() {
    for (final id in _held.keys.toList()) {
      _drop(id);
    }
  }

  void _drop(String id) {
    final held = _held.remove(id)!;
    for (final sub in held.subs) {
      sub.cancel();
    }
    unawaited(held.channel.dispose());
  }
}

/// Everything newer than [since] — the reconnect gap-fill, for either kind of
/// conversation.
///
/// Broadcast has no replay, so anything sent while the socket was down is
/// simply gone from the client's point of view. Reconnecting therefore cannot
/// mean "resume listening"; it has to mean "ask what I missed". Pages
/// backwards from the newest with [fetchPage] (newest-first, keyset on the
/// row passed as `before`) until it reaches [since], which is one round trip
/// for a normal blip and stays bounded for a long outage.
Future<List<ChatMessage>> fetchChatMessagesSince(
  Future<List<ChatMessage>> Function(ChatMessage? before, int limit) fetchPage,
  DateTime since, {
  int maxPages = 5,
  int pageSize = 50,
}) async {
  final gathered = <ChatMessage>[];
  ChatMessage? cursor;

  for (var page = 0; page < maxPages; page++) {
    final rows = await fetchPage(cursor, pageSize);
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

/// One conversation, as [ChatScreen] sees it.
///
/// The screen's behaviour — optimistic send, echo dedupe, keyset paging,
/// reconnect gap-fill — is the same for a party chat and a direct thread, and
/// lives in the screen once. What differs is which RPCs and which topic, and
/// that is all this interface carries. The two implementations bind a
/// repository to one conversation id and do nothing else; the rules about
/// who may read or write live on the server for both.
abstract class ChatSource {
  /// Who is signed in, so the bubbles know which side a message goes on.
  String? get currentUserId;

  /// Whether a long-press on SOMEONE ELSE's line offers "Hide message".
  /// True for a party chat, where the host may take a line down; false for a
  /// direct thread, where hiding is author-only — offering it would only ever
  /// produce a refusal.
  bool get canHideOthersMessages;

  Future<List<ChatMessage>> fetchMessages({ChatMessage? before, int limit = 30});
  Future<List<ChatMessage>> fetchMessagesSince(DateTime since);
  Future<ChatMessage> sendMessage(String body);
  Future<void> markRead();
  Future<void> hideMessage(String messageId);
  ChatChannel subscribe();
}

class PartyChatSource implements ChatSource {
  PartyChatSource(this.repository, this.partyId);

  final ChatRepository repository;
  final String partyId;

  @override
  String? get currentUserId => repository.currentUserId;

  @override
  bool get canHideOthersMessages => true;

  @override
  Future<List<ChatMessage>> fetchMessages({ChatMessage? before, int limit = 30}) =>
      repository.fetchMessages(partyId, before: before, limit: limit);

  @override
  Future<List<ChatMessage>> fetchMessagesSince(DateTime since) =>
      repository.fetchMessagesSince(partyId, since);

  @override
  Future<ChatMessage> sendMessage(String body) =>
      repository.sendMessage(partyId: partyId, body: body);

  @override
  Future<void> markRead() => repository.markRead(partyId);

  @override
  Future<void> hideMessage(String messageId) => repository.hideMessage(messageId);

  @override
  ChatChannel subscribe() => repository.subscribe(partyId);
}

class DirectChatSource implements ChatSource {
  DirectChatSource(this.repository, this.threadId);

  final DirectChatRepository repository;
  final String threadId;

  @override
  String? get currentUserId => repository.currentUserId;

  @override
  bool get canHideOthersMessages => false;

  @override
  Future<List<ChatMessage>> fetchMessages({ChatMessage? before, int limit = 30}) =>
      repository.fetchMessages(threadId, before: before, limit: limit);

  @override
  Future<List<ChatMessage>> fetchMessagesSince(DateTime since) =>
      repository.fetchMessagesSince(threadId, since);

  @override
  Future<ChatMessage> sendMessage(String body) =>
      repository.sendMessage(threadId: threadId, body: body);

  @override
  Future<void> markRead() => repository.markRead(threadId);

  @override
  Future<void> hideMessage(String messageId) => repository.hideMessage(messageId);

  @override
  ChatChannel subscribe() => repository.subscribe(threadId);
}
