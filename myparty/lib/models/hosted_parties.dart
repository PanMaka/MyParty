import 'party_summary.dart';

/// The profile's party list, already split into the two groups it renders.
///
/// Split by the SERVER, not here. `get_my_hosted_parties` computes
/// `is_upcoming` from the same `now()` that produced the ordering, so the group
/// a party lands in and the position it sorts to are decided by one clock in
/// one statement. Partitioning in Dart on `DateTime.now()` would introduce a
/// second clock: a party starting inside the round trip could be fetched as
/// upcoming and drawn as past, and a device with a skewed clock would disagree
/// with the server for as long as the skew lasted.
///
/// Both lists arrive in display order and must not be re-sorted. [upcoming] is
/// soonest-first — the next party you host at the top; [past] is most
/// recent-first — the one you just threw at the top.
class HostedParties {
  const HostedParties({required this.upcoming, required this.past});

  /// Starting now or later, soonest first.
  final List<PartySummary> upcoming;

  /// Already started, most recent first.
  final List<PartySummary> past;

  static const empty = HostedParties(upcoming: [], past: []);

  /// What the "ΠΑΡΤΙ · N" heading prints.
  ///
  /// Deliberately derived from the two rendered lists rather than from a
  /// separate count query. The number in a heading has to be the number of
  /// cards beneath it: a total fetched independently would drift from what is
  /// on screen the moment the RPC's `p_limit` truncated anything, and it would
  /// drift silently.
  int get total => upcoming.length + past.length;

  bool get isEmpty => total == 0;

  /// Rows come back as one ordered stream with a flag, and are split here
  /// preserving that order — `where` keeps the relative order of the source,
  /// and the source is already sorted the way both groups want to be read.
  factory HostedParties.fromRows(List<Map<String, dynamic>> rows) {
    final upcoming = <PartySummary>[];
    final past = <PartySummary>[];

    for (final row in rows) {
      final party = PartySummary.fromRow(row);
      // No `?? false` fallback that would silently file everything under past:
      // the column is a computed `boolean` and is never null, so a null here
      // would mean the RPC's shape changed and the loud failure is correct.
      if (row['is_upcoming'] as bool) {
        upcoming.add(party);
      } else {
        past.add(party);
      }
    }

    return HostedParties(upcoming: upcoming, past: past);
  }
}
