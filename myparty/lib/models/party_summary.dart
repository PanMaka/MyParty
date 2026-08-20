import 'package:flutter/material.dart';

/// A `public.parties` row reduced to what a profile card needs.
///
/// Deliberately carries no cover image. The `party-covers` bucket exists
/// (`{party_id}/…`, `20260812124217`) but **no column points into it** — the
/// same gap `profiles` has for avatars — so there is nothing to fetch and
/// [placeholderColors] is the honest stand-in. Add the field in the migration
/// that adds the column, not before.
///
/// Also carries no neighbourhood. The prototype's "Κουκάκι" had no column
/// behind it either: `parties.location` is a geography point, and there is no
/// address or area text anywhere in the schema.
class PartySummary {
  final String id;
  final String title;
  final DateTime startsAt;
  final bool isPrivate;
  final int goingCount;
  final int interestedCount;

  /// Nullable in the schema, and the nullability is load-bearing: it is the
  /// only real denominator a party has. A host who never set one has no
  /// "18/24" to show, so the card shows the count alone rather than inventing
  /// a target to divide by.
  final int? maxCapacity;

  const PartySummary({
    required this.id,
    required this.title,
    required this.startsAt,
    required this.isPrivate,
    required this.goingCount,
    required this.interestedCount,
    this.maxCapacity,
  });

  factory PartySummary.fromRow(Map<String, dynamic> row) {
    return PartySummary(
      id: row['id'] as String,
      title: row['title'] as String,
      startsAt: DateTime.parse(row['starts_at'] as String).toLocal(),
      isPrivate: (row['is_private'] as bool?) ?? false,
      goingCount: (row['going_count'] as int?) ?? 0,
      interestedCount: (row['interested_count'] as int?) ?? 0,
      maxCapacity: row['max_capacity'] as int?,
    );
  }

  /// True only when the host set a capacity. Guards the progress bar, which is
  /// meaningless without a denominator — the prototype's hardcoded
  /// `widthFactor: 0.75` was a picture of a ratio nothing computed.
  bool get hasCapacity => maxCapacity != null && maxCapacity! > 0;

  /// Clamped, because `going_count` can legitimately exceed `max_capacity`:
  /// the cap is not enforced by a constraint, and a host may raise or lower it
  /// after people have already said yes. An unclamped value would paint a bar
  /// past the end of its track.
  double get capacityFraction {
    if (!hasCapacity) return 0;
    return (goingCount / maxCapacity!).clamp(0.0, 1.0);
  }

  /// Stand-in for the cover the `party-covers` bucket will eventually serve,
  /// derived from the uuid so a party looks the same on every rebuild. Same
  /// device as `Profile.placeholderColors`.
  List<Color> get placeholderColors {
    final hue = (id.hashCode.abs() % 360).toDouble();
    return [
      HSLColor.fromAHSL(1, hue, 0.30, 0.18).toColor(),
      HSLColor.fromAHSL(1, hue, 0.28, 0.11).toColor(),
    ];
  }
}
