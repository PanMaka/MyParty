import '../state/mp_store.dart' show MpRsvp;

/// How `get_parties_list` orders its result.
///
/// Mirrors the `public.party_sort` enum one-for-one. It is an enum on the
/// server precisely so an unknown value is a type error at the API boundary
/// rather than a silent fallback, and [wireName] is the only place the two
/// spellings meet — a typo here surfaces as a 22P02 from Postgres naming the
/// legal values, not as a list quietly sorted the other way.
enum PartySort {
  soonest('soonest', 'Soonest'),
  interested('interested', 'Most interested');

  const PartySort(this.wireName, this.label);

  /// The `party_sort` value sent to the RPC.
  final String wireName;

  /// What the toggle shows.
  final String label;
}

/// One row of the ALL PARTIES list.
///
/// [goingCount] and [interestedCount] are **nullable, and null means private**
/// — `get_parties_list` returns NULL for both on a private row, exactly as
/// `get_parties_near_user` and `search_parties` do (20260825090051). They are
/// `int?` rather than `int` on purpose: a surface that forgets fails to
/// compile instead of rendering a confident 0.
///
/// [sortGroup] and [sortRank] are the row's own ordering keys, returned so the
/// client can echo them back as a cursor rather than reconstructing the key.
/// They are NOT for display. [sortRank] is 0 on every private row — the server
/// never consults a private party's counter to order it (see the migration's
/// Part 1), so the cursor carries no count either.
class PartyListItem {
  final String partyId;
  final String title;
  final String? description;
  final DateTime startsAt;
  final DateTime? endsAt;
  final String? area;
  final String? coverPath;
  final bool isPrivate;
  final bool isSponsored;
  final String hostId;
  final String hostUsername;

  /// Server-computed: the party has started and has not ended.
  ///
  /// From the server rather than derived here, so the list's grouping and the
  /// card's badge cannot disagree — the row was placed in the "live" group by
  /// the same comparison that set this.
  final bool isLive;

  final int? goingCount;
  final int? interestedCount;
  final MpRsvp? myRsvp;
  final bool isInvited;

  final int sortGroup;
  final int sortRank;

  const PartyListItem({
    required this.partyId,
    required this.title,
    required this.description,
    required this.startsAt,
    required this.endsAt,
    required this.area,
    required this.coverPath,
    required this.isPrivate,
    required this.isSponsored,
    required this.hostId,
    required this.hostUsername,
    required this.isLive,
    required this.goingCount,
    required this.interestedCount,
    required this.myRsvp,
    required this.isInvited,
    required this.sortGroup,
    required this.sortRank,
  });

  factory PartyListItem.fromRow(Map<String, dynamic> row) {
    return PartyListItem(
      partyId: row['party_id'] as String,
      title: row['title'] as String,
      description: row['description'] as String?,
      startsAt: DateTime.parse(row['starts_at'] as String).toLocal(),
      endsAt: row['ends_at'] == null ? null : DateTime.parse(row['ends_at'] as String).toLocal(),
      area: row['area'] as String?,
      coverPath: row['cover_path'] as String?,
      isPrivate: row['is_private'] as bool,
      isSponsored: (row['is_sponsored'] as bool?) ?? false,
      hostId: row['host_id'] as String,
      hostUsername: row['host_username'] as String,
      isLive: (row['is_live'] as bool?) ?? false,
      goingCount: row['going_count'] as int?,
      interestedCount: row['interested_count'] as int?,
      myRsvp: switch (row['my_rsvp_status'] as String?) {
        'going' => MpRsvp.going,
        'interested' => MpRsvp.interested,
        _ => null,
      },
      isInvited: (row['is_invited'] as bool?) ?? false,
      sortGroup: row['sort_group'] as int,
      sortRank: row['sort_rank'] as int,
    );
  }

  /// Whether this row reports attendance at all — true exactly when it is
  /// public.
  ///
  /// Derived from the payload rather than from [isPrivate], the same way
  /// [MapPartyPin.hasCounts] is: if a future migration suppressed counts for
  /// some other reason, every surface follows without being edited.
  bool get hasCounts => goingCount != null && interestedCount != null;

  /// The one number a card prints, and which of the two it is depends on the
  /// tense: a live party reports who is *inside* it, one that has not started
  /// reports who is interested.
  ///
  /// Since 20260826093437 the second is a SUPERSET of the first, so this can
  /// only fall as a party starts. Null for a private party, all the way
  /// through — callers branch on null rather than being handed a zero.
  int? get attendeeCount => isLive ? goingCount : interestedCount;

  /// The label that goes with [attendeeCount], so the number and its noun can
  /// never disagree about which counter was read.
  String? get attendeeLabel {
    final n = attendeeCount;
    if (n == null) return null;
    return isLive ? '$n here now' : '$n interested';
  }

  /// A private party takes only 'going' (20260825090050), so its card offers
  /// one button rather than two.
  bool get acceptsInterested => !isPrivate;

  PartyListItem copyWith({MpRsvp? myRsvp, bool clearRsvp = false}) {
    return PartyListItem(
      partyId: partyId,
      title: title,
      description: description,
      startsAt: startsAt,
      endsAt: endsAt,
      area: area,
      coverPath: coverPath,
      isPrivate: isPrivate,
      isSponsored: isSponsored,
      hostId: hostId,
      hostUsername: hostUsername,
      isLive: isLive,
      goingCount: goingCount,
      interestedCount: interestedCount,
      myRsvp: clearRsvp ? null : (myRsvp ?? this.myRsvp),
      isInvited: isInvited,
      sortGroup: sortGroup,
      sortRank: sortRank,
    );
  }
}

/// The keyset cursor: one row's ordering keys, echoed back to get the next
/// page.
///
/// Four components because both sorts are normalised to the same ascending
/// 4-tuple on the server — there is deliberately no second cursor shape for
/// the second sort. Carries no count: [sortRank] is `-interested_count` only
/// for PUBLIC rows on the interested sort, and 0 everywhere else.
class PartyListCursor {
  final int sortGroup;
  final int sortRank;
  final DateTime startsAt;
  final String partyId;

  const PartyListCursor({
    required this.sortGroup,
    required this.sortRank,
    required this.startsAt,
    required this.partyId,
  });

  factory PartyListCursor.fromItem(PartyListItem item) => PartyListCursor(
        sortGroup: item.sortGroup,
        sortRank: item.sortRank,
        startsAt: item.startsAt,
        partyId: item.partyId,
      );
}

/// A page of the list plus the cursor that continues it.
///
/// [cursor] is null exactly when there is nothing more to fetch, so the caller
/// never has to compare `items.length` against the limit it asked for.
class PartyListPage {
  final List<PartyListItem> items;
  final PartyListCursor? cursor;

  const PartyListPage({required this.items, required this.cursor});
}
