/// Where a party is in its life, as the host dashboard labels it.
///
/// Derived from the server's `status`, `is_live` and `is_over` (one clock,
/// the server's — see [HostPartyStats]), never from `DateTime.now()` here.
enum HostPartyPhase {
  upcoming('UPCOMING'),
  live('LIVE'),
  ended('ENDED'),
  cancelled('CANCELLED');

  const HostPartyPhase(this.label);
  final String label;
}

/// One group's gender mix on the host dashboard: counts only, never who.
///
/// [unspecified] is everyone with no saved answer, "prefer not to say"
/// included. The four always sum to the group's size.
class GenderMix {
  const GenderMix({required this.male, required this.female, required this.nonBinary, required this.unspecified});

  final int male;
  final int female;
  final int nonBinary;
  final int unspecified;

  int get total => male + female + nonBinary + unspecified;

  /// The server sends all four or none: NULL for a group under its minimum
  /// of three (20261019193257), which is decided there, not here.
  static GenderMix? fromRow(Map<String, dynamic> row, String prefix) {
    final male = row['${prefix}_male'] as int?;
    final female = row['${prefix}_female'] as int?;
    final nonBinary = row['${prefix}_non_binary'] as int?;
    final unspecified = row['${prefix}_unspecified'] as int?;
    if (male == null || female == null || nonBinary == null || unspecified == null) return null;
    return GenderMix(male: male, female: female, nonBinary: nonBinary, unspecified: unspecified);
  }
}

/// One row of `get_party_host_stats` (20261014113213): the dashboard's header
/// and its aggregates. Host-only on the server.
///
/// Unlike every attendee-facing model, [goingCount] and [interestedCount] are
/// plain `int`s even on a private party: the host is the one caller the
/// server answers them for. [interestedCount] is still the SUPERSET of
/// [goingCount] (20260826093437) — the two are never added together.
class HostPartyStats {
  const HostPartyStats({
    required this.partyId,
    required this.title,
    required this.description,
    required this.area,
    required this.startsAt,
    required this.endsAt,
    required this.coverPath,
    required this.isPrivate,
    required this.status,
    required this.lat,
    required this.lng,
    required this.isLive,
    required this.isOver,
    required this.goingCount,
    required this.interestedCount,
    required this.goingFollowers,
    required this.goingNonFollowers,
    required this.interestedFollowers,
    required this.interestedNonFollowers,
    this.goingGender,
    this.interestedGender,
  });

  final String partyId;
  final String title;
  final String? description;
  final String? area;
  final DateTime startsAt;
  final DateTime? endsAt;
  final String? coverPath;
  final bool isPrivate;

  /// `party_status`: 'draft', 'published' or 'cancelled'.
  final String status;
  final double lat;
  final double lng;
  final bool isLive;
  final bool isOver;
  final int goingCount;
  final int interestedCount;

  /// "Follower" means someone who follows the HOST (gotcha 14). Counted over
  /// every rsvp, block-paired guests included, so these can add up to more
  /// than the guest list shows — the list hides a name, the number does not.
  final int goingFollowers;
  final int goingNonFollowers;
  final int interestedFollowers;
  final int interestedNonFollowers;

  /// Null means "not enough guests yet": the server withholds the mix of a
  /// group under three. Counted like the follower split, block-paired guests
  /// included. A private party's Coming is [goingGender].
  final GenderMix? goingGender;
  final GenderMix? interestedGender;

  factory HostPartyStats.fromRow(Map<String, dynamic> row) {
    DateTime? ts(Object? v) => v is String ? DateTime.parse(v).toLocal() : null;
    return HostPartyStats(
      partyId: row['party_id'] as String,
      title: row['title'] as String,
      description: row['description'] as String?,
      area: row['area'] as String?,
      startsAt: ts(row['starts_at'])!,
      endsAt: ts(row['ends_at']),
      coverPath: row['cover_path'] as String?,
      isPrivate: row['is_private'] as bool,
      status: row['status'] as String,
      lat: (row['lat'] as num).toDouble(),
      lng: (row['lon'] as num).toDouble(),
      isLive: row['is_live'] as bool,
      isOver: row['is_over'] as bool,
      goingCount: row['going_count'] as int,
      interestedCount: row['interested_count'] as int,
      goingFollowers: row['going_followers'] as int,
      goingNonFollowers: row['going_non_followers'] as int,
      interestedFollowers: row['interested_followers'] as int,
      interestedNonFollowers: row['interested_non_followers'] as int,
      goingGender: GenderMix.fromRow(row, 'going'),
      interestedGender: GenderMix.fromRow(row, 'interested'),
    );
  }

  HostPartyPhase get phase {
    if (status == 'cancelled') return HostPartyPhase.cancelled;
    if (isLive) return HostPartyPhase.live;
    if (isOver) return HostPartyPhase.ended;
    return HostPartyPhase.upcoming;
  }

  bool get isCancelled => status == 'cancelled';

  /// Editable and cancellable: what `update_party` and `cancel_party` accept.
  bool get isPublished => status == 'published';
}

/// One row of the host's guest list (`get_party_guests`).
class PartyGuest {
  const PartyGuest({
    required this.userId,
    required this.username,
    required this.avatarPath,
    required this.going,
    required this.followsHost,
    required this.createdAt,
  });

  final String userId;
  final String username;
  final String? avatarPath;

  /// True for status 'going'. The Interested tab lists everyone (interested is
  /// the superset), and badges these.
  final bool going;
  final bool followsHost;
  final DateTime createdAt;

  factory PartyGuest.fromRow(Map<String, dynamic> row) => PartyGuest(
        userId: row['user_id'] as String,
        username: row['username'] as String,
        avatarPath: row['avatar_path'] as String?,
        going: row['status'] == 'going',
        followsHost: (row['follows_host'] as bool?) ?? false,
        // Kept in UTC: it is only ever echoed back as the keyset cursor.
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}

/// A page of guests and the cursor that continues it — null at the end.
class PartyGuestPage {
  const PartyGuestPage({required this.guests, required this.cursor});

  final List<PartyGuest> guests;
  final PartyGuest? cursor;
}

/// Everything `update_party` takes. Full replacement, so null means null.
class PartyEdit {
  const PartyEdit({
    required this.partyId,
    required this.title,
    required this.description,
    required this.area,
    required this.startsAt,
    required this.endsAt,
    required this.lat,
    required this.lng,
  });

  final String partyId;
  final String title;
  final String? description;
  final String? area;
  final DateTime startsAt;
  final DateTime? endsAt;
  final double lat;
  final double lng;
}

/// One of the host's followers, as the invite picker shows them
/// (`get_invitable_followers`).
///
/// [alreadyInvited] or a non-null [rsvpStatus] locks the row: inviting again
/// would change nothing.
class InvitableFollower {
  const InvitableFollower({
    required this.userId,
    required this.username,
    required this.avatarPath,
    required this.alreadyInvited,
    required this.rsvpStatus,
  });

  final String userId;
  final String username;
  final String? avatarPath;
  final bool alreadyInvited;

  /// 'going', 'interested' or null.
  final String? rsvpStatus;

  bool get locked => alreadyInvited || rsvpStatus != null;

  factory InvitableFollower.fromRow(Map<String, dynamic> row) => InvitableFollower(
        userId: row['user_id'] as String,
        username: row['username'] as String,
        avatarPath: row['avatar_path'] as String?,
        alreadyInvited: (row['already_invited'] as bool?) ?? false,
        rsvpStatus: row['rsvp_status'] as String?,
      );
}

/// A page of the picker, alphabetical; [cursor] is null at the end.
class InvitableFollowerPage {
  const InvitableFollowerPage({required this.followers, required this.cursor});

  final List<InvitableFollower> followers;
  final InvitableFollower? cursor;
}

/// One invitation on the party, for the host's Invited tab
/// (`get_party_invitees`).
class PartyInvitee {
  const PartyInvitee({
    required this.userId,
    required this.username,
    required this.avatarPath,
    required this.rsvpStatus,
    required this.viaLink,
    required this.createdAt,
  });

  final String userId;
  final String username;
  final String? avatarPath;

  /// 'going', 'interested' or null for "invited, has not answered".
  final String? rsvpStatus;

  /// Came in through the party's invite link rather than a direct invite.
  final bool viaLink;

  /// UTC; only ever echoed back as the keyset cursor.
  final DateTime createdAt;

  factory PartyInvitee.fromRow(Map<String, dynamic> row) => PartyInvitee(
        userId: row['user_id'] as String,
        username: row['username'] as String,
        avatarPath: row['avatar_path'] as String?,
        rsvpStatus: row['rsvp_status'] as String?,
        viaLink: (row['via_link'] as bool?) ?? false,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}

class PartyInviteePage {
  const PartyInviteePage({required this.invitees, required this.cursor});

  final List<PartyInvitee> invitees;
  final PartyInvitee? cursor;
}

/// The party's active invite link, as `get_party_invite_link` describes it —
/// never the token, which the server does not keep.
class InviteLinkStatus {
  const InviteLinkStatus({required this.createdAt, required this.maxUses, required this.useCount});

  final DateTime createdAt;
  final int? maxUses;
  final int useCount;

  bool get usedUp => maxUses != null && useCount >= maxUses!;

  factory InviteLinkStatus.fromRow(Map<String, dynamic> row) => InviteLinkStatus(
        createdAt: DateTime.parse(row['created_at'] as String),
        maxUses: row['max_uses'] as int?,
        useCount: row['use_count'] as int,
      );
}
