import 'package:flutter/material.dart';

/// A `public.parties` row reduced to what a profile card needs.
///
/// Both of this class's documented gaps closed in `20260820095801`:
/// `parties.cover_path` now points into the `party-covers` bucket, and
/// `parties.area` holds the neighbourhood line the prototype's "Κουκάκι" had
/// nothing behind. Both are nullable, and both stay nullable on purpose —
/// [placeholderColors] is what an absent cover draws, and an absent area draws
/// nothing at all rather than a guess.
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

  /// Path into the **private** `party-covers` bucket (`{party_id}/…`), never a
  /// URL, and null when the host uploaded no cover.
  ///
  /// Unlike `Profile.avatarPath`, holding this key is not enough to draw it:
  /// `party-covers` is not a public bucket, so rendering needs a signed URL
  /// issued server-side. A non-null value here therefore means "a cover exists
  /// and you may ask for it", not "here is an image" — which is exactly why the
  /// column stores a key and not a link that would go stale in an hour.
  final String? coverPath;

  /// The host's neighbourhood label ("Κουκάκι"), or null when they did not say.
  ///
  /// **Null is not "unknown, so compute it".** There is no derivation available
  /// and deliberately so: reverse geocoding `parties.location` would ship a
  /// private party's coordinates to a geocoder, which is the one thing the
  /// location work in Phase 7 exists to prevent. A card with no area shows no
  /// area line — it does not fall back to a city, a district, or a coordinate.
  ///
  /// Guaranteed non-blank, single-line and ≤80 characters by
  /// `parties_area_one_short_line`, on the same reasoning as `Profile.bio`.
  final String? area;

  const PartySummary({
    required this.id,
    required this.title,
    required this.startsAt,
    required this.isPrivate,
    required this.goingCount,
    required this.interestedCount,
    this.maxCapacity,
    this.coverPath,
    this.area,
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
      // Both stay null when absent. The `?? 0` defaults above are for counters,
      // where zero is the true value of "nobody yet"; there is no equivalent
      // true value for a missing image or an unstated neighbourhood, so
      // defaulting either would be inventing one.
      coverPath: row['cover_path'] as String?,
      area: row['area'] as String?,
    );
  }

  /// True only when the host uploaded a cover. Guards the image the same way
  /// [hasCapacity] guards the progress bar.
  bool get hasCover => coverPath != null;

  /// True only when the host wrote a neighbourhood.
  bool get hasArea => area != null;

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

  /// The cover fallback, for the [hasCover] == false case — derived from the
  /// uuid so a party looks the same on every rebuild. Same device as
  /// `Profile.placeholderColors`, and no longer a stand-in for a missing
  /// column: [coverPath] exists now, and this is what gets drawn when it is
  /// null or while its signed URL is still being fetched.
  List<Color> get placeholderColors {
    final hue = (id.hashCode.abs() % 360).toDouble();
    return [
      HSLColor.fromAHSL(1, hue, 0.30, 0.18).toColor(),
      HSLColor.fromAHSL(1, hue, 0.28, 0.11).toColor(),
    ];
  }
}
