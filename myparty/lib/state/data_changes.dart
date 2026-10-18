import 'dart:async';

import 'mp_store.dart';

/// Something the viewer just wrote, announced to every screen that shows it.
///
/// The tabs are kept alive in a PageView and pushed screens outlive the tab under
/// them, so a screen built once never rebuilds because another one wrote
/// something: a follow on someone's profile would leave every other copy of
/// that profile on its old count, and a party hosted from the wizard would
/// never reach MY PARTIES, the profile or the map. This stream is how they
/// hear.
///
/// **Published by the repositories, after the write succeeded.** Never by a
/// widget, so no call site can forget, and never before the server said yes,
/// so a listener only ever reacts to the server's state. The optimistic half
/// — the button or counter under the user's thumb moving at once and rolling
/// back on failure — belongs to the screen the tap happened on, and stays
/// there: a rollback that only one screen ever saw needs no announcing.
///
/// Generalises `rsvpChanges`, which did this for one action and is now
/// [RsvpChanged].
sealed class DataChange {
  const DataChange();
}

/// The viewer's rsvps row for [partyId] changed: [status] is their answer
/// now, null when they withdrew it.
final class RsvpChanged extends DataChange {
  const RsvpChanged({required this.partyId, required this.status});

  final String partyId;
  final MpRsvp? status;
}

/// The cover of [partyId] finished uploading. Separate from [PartyCreated]
/// because the cover lands after the party does: a list that refetched on
/// the creation would otherwise keep a placeholder where the photo now is.
final class PartyCoverChanged extends DataChange {
  const PartyCoverChanged({required this.partyId});

  final String partyId;
}

/// The viewer started ([following] true) or stopped following [targetUserId].
/// The target's `follower_count` moved by one on the server.
final class FollowChanged extends DataChange {
  const FollowChanged({required this.targetUserId, required this.following});

  final String targetUserId;
  final bool following;
}

/// The viewer hosted a new party. Published once the party row exists, which
/// is before the cover upload — a party with a failed cover is still live.
final class PartyCreated extends DataChange {
  const PartyCreated({required this.partyId});

  final String partyId;
}

/// The viewer edited [partyId]'s details (title, times, place, description)
/// through `update_party`. Every list showing the party is out of date.
final class PartyUpdated extends DataChange {
  const PartyUpdated({required this.partyId});

  final String partyId;
}

/// The viewer cancelled [partyId]. It leaves the map, the lists and its link
/// (they all filter on status = 'published'); only its host dashboard stays.
final class PartyCancelled extends DataChange {
  const PartyCancelled({required this.partyId});

  final String partyId;
}

/// The viewer, as host, changed who is on [partyId]'s guest list: invited
/// people, or removed someone. The dashboard's tabs and counters are stale.
final class PartyGuestsChanged extends DataChange {
  const PartyGuestsChanged({required this.partyId});

  final String partyId;
}

/// The viewer joined [partyId] through an invite link. It is a new row in
/// their MY PARTIES and, for a private party, a new pin on their map.
final class InviteRedeemed extends DataChange {
  const InviteRedeemed({required this.partyId});

  final String partyId;
}

/// The viewer's read marker for a conversation moved to now, so its unread
/// count is zero. [direct] tells a DM thread id from a party id.
final class ConversationRead extends DataChange {
  const ConversationRead({required this.conversationId, required this.direct});

  final String conversationId;
  final bool direct;
}

/// The viewer sent a message, so the conversation's preview and its place in
/// the chat list changed.
final class MessageSent extends DataChange {
  const MessageSent({required this.conversationId, required this.direct});

  final String conversationId;
  final bool direct;
}

/// The viewer hid a message. The hide RPCs take only a message id, so the
/// conversation is not known here; a list that might be previewing it
/// refetches.
final class MessageHidden extends DataChange {
  const MessageHidden({required this.direct});

  final bool direct;
}

/// The viewer blocked ([blocked] true) or unblocked [userId]. Wide on
/// purpose: a block hides the pair from each other in every policy, so their
/// profile, their parties, their DM thread and their follow edges all change.
final class BlockChanged extends DataChange {
  const BlockChanged({required this.userId, required this.blocked});

  final String userId;
  final bool blocked;
}

/// The app-wide bus. A plain global rather than a Provider so a widget test
/// that pumps one screen with no app providers above it still builds — the
/// same reason `rsvpChanges` was one.
class DataChanges {
  // Asynchronous delivery: a listener that reacts by writing (and so
  // publishing) cannot re-enter a delivery in progress.
  final StreamController<DataChange> _controller =
      StreamController<DataChange>.broadcast();

  Stream<DataChange> get stream => _controller.stream;

  void publish(DataChange change) => _controller.add(change);
}

final DataChanges dataChanges = DataChanges();

/// The wire value of `my_rsvp_status` as an [MpRsvp], null for "no row".
MpRsvp? parseRsvpStatus(String? value) => switch (value) {
      'going' => MpRsvp.going,
      'interested' => MpRsvp.interested,
      _ => null,
    };
