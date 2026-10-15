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

/// `get_party_rsvp_timeline`'s bucket width. Mirrors `public.stats_bucket`.
enum StatsBucket { hour, day }

/// Cumulative counters at the end of one bucket.
class RsvpTimelinePoint {
  const RsvpTimelinePoint({required this.at, required this.going, required this.interested});

  final DateTime at;
  final int going;
  final int interested;
}

/// The over-time chart's data. Empty [points] means no rsvp was ever made —
/// the server returns no rows rather than a flat line at zero.
class RsvpTimeline {
  const RsvpTimeline({required this.bucket, required this.points});

  final StatsBucket bucket;
  final List<RsvpTimelinePoint> points;

  bool get isEmpty => points.isEmpty;

  factory RsvpTimeline.fromRows(List<Map<String, dynamic>> rows) {
    final bucket = rows.isNotEmpty && rows.first['bucket'] == 'day' ? StatsBucket.day : StatsBucket.hour;
    return RsvpTimeline(
      bucket: bucket,
      points: [
        for (final row in rows)
          RsvpTimelinePoint(
            at: DateTime.parse(row['bucket_start'] as String).toLocal(),
            going: row['going'] as int,
            interested: row['interested'] as int,
          ),
      ],
    );
  }
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
