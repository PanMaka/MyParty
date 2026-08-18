/// The three counters on the profile screen, from `get_profile_stats`.
///
/// Every count is **already filtered to what the caller may see** — the RPC is
/// `security invoker`, so the `rsvps`, `parties` and `stories` SELECT policies
/// run inside it. Two consequences worth knowing before using this type:
///
///  * [partiesHosted] is legitimately *smaller* when you are looking at someone
///    else's profile. Their private parties are not yours to count.
///  * [partiesAttended] is **zero for anyone but the owner**, always. The
///    `rsvps` SELECT policy is `user_id = auth.uid() OR I host the party`, so
///    there is no viewer other than the owner for whom this can be non-zero.
///    That is not a bug to route around — "who sees which parties I go to" is a
///    real setting that does not exist yet, and the RPC deliberately does not
///    invent an answer for it. Which is why the screen renders that tile in the
///    self view only; showing a hard zero on someone else's profile would read
///    as "they go to nothing" rather than "you may not know".
class ProfileStats {
  const ProfileStats({
    required this.partiesAttended,
    required this.partiesHosted,
    required this.storiesPosted,
  });

  /// Parties with a `going` RSVP whose start falls in the current calendar year
  /// — the "πάρτι φέτος" tile. Owner-only, see the class doc.
  final int partiesAttended;

  /// Published parties hosted, filtered to those the caller may see.
  final int partiesHosted;

  /// Stories posted and not hidden, filtered to those the caller may see.
  final int storiesPosted;

  static const empty = ProfileStats(partiesAttended: 0, partiesHosted: 0, storiesPosted: 0);

  factory ProfileStats.fromRow(Map<String, dynamic> row) {
    return ProfileStats(
      partiesAttended: (row['parties_attended'] as int?) ?? 0,
      partiesHosted: (row['parties_hosted'] as int?) ?? 0,
      storiesPosted: (row['stories_posted'] as int?) ?? 0,
    );
  }
}
