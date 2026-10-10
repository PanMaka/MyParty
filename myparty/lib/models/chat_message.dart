/// Where a message is in its journey from "typed" to "stored".
///
/// Only [sent] rows exist server-side. The other two are local states an
/// optimistic send passes through, and they are what let the bubble render
/// before the insert round-trips without ever lying about what is durable.
enum MessageStatus {
  /// Rendered locally, insert still in flight.
  sending,

  /// The insert was rejected. The bubble stays on screen with a retry
  /// affordance rather than vanishing — a message that silently disappears
  /// after you hit send is worse than one that says it failed.
  failed,

  /// Confirmed by the server, either by the insert returning or by the
  /// broadcast echo arriving.
  sent,
}

/// One message in a conversation — a party chat or a direct thread.
///
/// One row of `get_messages` or `get_direct_messages`, or one `new_message`
/// broadcast payload from either topic. They carry the same fields on
/// purpose, so the live path and the history path produce identical objects
/// and the UI never has to care which one a bubble came from — nor, since
/// Phase 33, which kind of conversation it belongs to.
class ChatMessage {
  final String id;

  /// The party id for a party chat, the thread id for a direct message. The
  /// screen only ever compares it with the conversation it is showing, so it
  /// does not need to know which.
  final String conversationId;
  final String authorId;
  final String authorUsername;
  final String body;
  final DateTime createdAt;
  final MessageStatus status;

  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.authorId,
    required this.authorUsername,
    required this.body,
    required this.createdAt,
    this.status = MessageStatus.sent,
  });

  /// A row from `get_messages` (keyed `party_id`) or `get_direct_messages`
  /// (keyed `thread_id`).
  factory ChatMessage.fromRow(Map<String, dynamic> row) {
    return ChatMessage(
      id: row['id'] as String,
      conversationId: (row['party_id'] ?? row['thread_id']) as String,
      authorId: row['author_id'] as String,
      authorUsername: (row['author_username'] as String?) ?? '',
      body: row['body'] as String,
      // Kept in UTC: this doubles as the keyset cursor and has to go back to
      // the RPC exactly as it came out. Same rule as FeedPost.createdAt.
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      status: MessageStatus.sent,
    );
  }

  /// A `new_message` broadcast payload. Shaped by `broadcast_message` and
  /// `broadcast_direct_message`, which build it with the same keys the read
  /// RPCs return.
  factory ChatMessage.fromBroadcast(Map<String, dynamic> payload) =>
      ChatMessage.fromRow(payload);

  ChatMessage copyWith({MessageStatus? status}) {
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      authorId: authorId,
      authorUsername: authorUsername,
      body: body,
      createdAt: createdAt,
      status: status ?? this.status,
    );
  }

  /// Messages sort by `(created_at, id)` — the same composite key the server
  /// paginates on. Several people hitting send in the same instant is the
  /// normal busy-party pattern, so the timestamp alone is not a total order
  /// and the id is what breaks the tie, on both sides of the wire.
  int compareTo(ChatMessage other) {
    final byTime = createdAt.compareTo(other.createdAt);
    return byTime != 0 ? byTime : id.compareTo(other.id);
  }
}

/// One row of `public.get_party_chats` — a party chat as it appears in the
/// list, with its preview and unread badge.
class PartyChatSummary {
  final String partyId;
  final String partyTitle;
  final bool isPrivate;
  final DateTime startsAt;
  final int goingCount;
  final String? lastMessageBody;
  final String? lastMessageAuthorUsername;
  final DateTime? lastMessageAt;

  /// Capped at 100 server-side so the count stays index-bounded no matter how
  /// far behind the user is — see the header of the `get_party_chats`
  /// migration. [unreadLabel] is what renders that cap honestly.
  final int unreadCount;

  const PartyChatSummary({
    required this.partyId,
    required this.partyTitle,
    required this.isPrivate,
    required this.startsAt,
    required this.goingCount,
    required this.lastMessageBody,
    required this.lastMessageAuthorUsername,
    required this.lastMessageAt,
    required this.unreadCount,
  });

  factory PartyChatSummary.fromRow(Map<String, dynamic> row) {
    final lastAt = row['last_message_at'] as String?;
    return PartyChatSummary(
      partyId: row['party_id'] as String,
      partyTitle: row['party_title'] as String,
      isPrivate: (row['party_is_private'] as bool?) ?? false,
      startsAt: DateTime.parse(row['party_starts_at'] as String).toLocal(),
      goingCount: (row['going_count'] as int?) ?? 0,
      lastMessageBody: row['last_message_body'] as String?,
      lastMessageAuthorUsername: row['last_message_author_username'] as String?,
      lastMessageAt: lastAt == null ? null : DateTime.parse(lastAt).toLocal(),
      unreadCount: (row['unread_count'] as int?) ?? 0,
    );
  }

  String get unreadLabel => unreadCount >= 100 ? '99+' : '$unreadCount';
}

/// One row of `public.get_direct_chats` — a 1-on-1 thread as it appears in the
/// Direct tab.
class DirectChatSummary {
  final String threadId;
  final String peerId;
  final String peerUsername;
  final String? peerAvatarPath;
  final String? lastMessageBody;
  final String? lastMessageAuthorId;

  /// The newest VISIBLE line, for the preview. Null when every line in the
  /// thread has been hidden.
  final DateTime? lastMessageAt;

  /// The thread's `last_message_at`, in UTC, exactly as the server sent it —
  /// the keyset cursor, echoed back with [threadId] to fetch the next page.
  /// Can be later than [lastMessageAt] when the newest line was hidden.
  final DateTime activityAt;

  /// Capped at 100 server-side, like [PartyChatSummary.unreadCount]. Counts
  /// only the peer's lines.
  final int unreadCount;

  const DirectChatSummary({
    required this.threadId,
    required this.peerId,
    required this.peerUsername,
    required this.peerAvatarPath,
    required this.lastMessageBody,
    required this.lastMessageAuthorId,
    required this.lastMessageAt,
    required this.activityAt,
    required this.unreadCount,
  });

  factory DirectChatSummary.fromRow(Map<String, dynamic> row) {
    final lastAt = row['last_message_at'] as String?;
    return DirectChatSummary(
      threadId: row['thread_id'] as String,
      peerId: row['peer_id'] as String,
      peerUsername: row['peer_username'] as String,
      peerAvatarPath: row['peer_avatar_path'] as String?,
      lastMessageBody: row['last_message_body'] as String?,
      lastMessageAuthorId: row['last_message_author_id'] as String?,
      lastMessageAt: lastAt == null ? null : DateTime.parse(lastAt).toLocal(),
      activityAt: DateTime.parse(row['activity_at'] as String).toUtc(),
      unreadCount: (row['unread_count'] as int?) ?? 0,
    );
  }

  String get unreadLabel => unreadCount >= 100 ? '99+' : '$unreadCount';
}
