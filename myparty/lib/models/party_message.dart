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

/// One row of `public.messages`, or one `new_message` broadcast payload —
/// they carry the same fields on purpose, so the live path and the history
/// path produce identical objects and the UI never has to care which one a
/// bubble came from.
class PartyMessage {
  final String id;
  final String partyId;
  final String authorId;
  final String authorUsername;
  final String body;
  final DateTime createdAt;
  final MessageStatus status;

  const PartyMessage({
    required this.id,
    required this.partyId,
    required this.authorId,
    required this.authorUsername,
    required this.body,
    required this.createdAt,
    this.status = MessageStatus.sent,
  });

  /// A row from `public.get_messages`.
  factory PartyMessage.fromRow(Map<String, dynamic> row) {
    return PartyMessage(
      id: row['id'] as String,
      partyId: row['party_id'] as String,
      authorId: row['author_id'] as String,
      authorUsername: (row['author_username'] as String?) ?? '',
      body: row['body'] as String,
      // Kept in UTC: this doubles as the keyset cursor and has to go back to
      // the RPC exactly as it came out. Same rule as FeedPost.createdAt.
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      status: MessageStatus.sent,
    );
  }

  /// A `new_message` broadcast payload. Shaped by `public.broadcast_message`,
  /// which builds it with the same keys `get_messages` returns.
  factory PartyMessage.fromBroadcast(Map<String, dynamic> payload) =>
      PartyMessage.fromRow(payload);

  PartyMessage copyWith({MessageStatus? status}) {
    return PartyMessage(
      id: id,
      partyId: partyId,
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
  int compareTo(PartyMessage other) {
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
