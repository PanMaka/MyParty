import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../models/map_party_pin.dart';

/// The geometry of a map bubble — a round body drawn down into a wide, low
/// cone with a generously rounded apex, sitting on the party's actual
/// coordinate. A water droplet at rest rather than one falling.
///
/// **The apex is the anchor, and that is the whole reason for the shape.** A
/// rounded-rect pill has no distinguished point, so it has to be positioned by
/// one of its edges and the reader infers the location from the middle of a
/// box. A bubble says exactly where it means. That only holds if the apex
/// stays on the coordinate as the bubble grows, so everything here is measured
/// from [tip] outward rather than from the box.
///
/// **Both joins are tangent-continuous, not eyeballed.** Each flank is a cubic
/// that leaves the body circle along its tangent and arrives at the apex arc
/// along *its* tangent, so neither join leaves a crease. A curve drawn to a
/// guessed point on the circle creases visibly at the large sizes and
/// invisibly at the small ones, which is the worst way to be wrong.
@immutable
class MpDropGeometry {
  const MpDropGeometry._({required this.radius, required this.isPrivate});

  /// How far the apex sits from the body circle's centre, in radii.
  ///
  /// 1.45 rather than the 2.2 the teardrop used: the cone is shorter and
  /// therefore wider at its mouth (θ ≈ 46° rather than 63°), which is what
  /// makes the silhouette read as bubbly instead of pointed. It also means the
  /// bubble covers less basemap below the coordinate than the teardrop did at
  /// the same radius.
  static const double tipRatio = 1.45;

  /// The apex's own corner radius, in radii. This is the single number that
  /// decides how soft the point is: at 0 the flanks meet in a sharp corner and
  /// the shape is a teardrop again; much past 0.35 the apex stops reading as a
  /// point at all and the bubble no longer says where it means.
  static const double apexRatio = 0.30;

  /// Where each flank meets the apex arc, measured from straight down. Fixes
  /// how much of the bottom is round: at 42° the apex arc covers 84° of turn.
  static const double apexContactAngle = 42 * math.pi / 180;

  /// How far the flank's control points reach along their tangents, as a
  /// fraction of the straight-line distance between the two joins. Pure
  /// shaping: bigger bulges the flank outward, smaller pulls it toward a
  /// straight line.
  static const double flankTension = 0.42;

  /// The public size range.
  ///
  /// The floor rose from 16 to 17 and the ceiling fell from 36 to 34 when the
  /// label moved inside: the smallest bubble now has to hold two digits
  /// legibly, and the largest no longer has to hold a thumbnail, a title and a
  /// count. The range is narrower than the teardrop's but every pixel of it is
  /// now spent on the one signal.
  static const double minRadius = 17;
  static const double maxRadius = 34;

  /// The count at which the public scale saturates. Beyond this a party is
  /// "as big as the map draws"; the label still carries the exact number.
  ///
  /// This number is doing a second job now that the count is drawn inside the
  /// bubble. A three-digit count is by definition ≥ 100, and 100 is where the
  /// radius saturates — so **a label that needs three glyphs can only ever
  /// appear on a bubble already at [maxRadius]**, and a bubble below that is
  /// guaranteed at most two. The label cannot outgrow its container, which is
  /// why there is no ellipsis anywhere on a pin any more.
  static const int saturatesAt = 100;

  final double radius;
  final bool isPrivate;

  /// The marker box. Width is the body circle's diameter — the widest part of
  /// the shape is its equator, since both flanks turn inward from their
  /// tangent points. Height runs from the top of the circle to the apex.
  double get width => 2 * radius;
  double get height => radius * (1 + tipRatio);

  Offset get center => Offset(radius, radius);
  Offset get tip => Offset(radius, height);

  /// The largest inscribed square inside the body circle, which is what any
  /// content drawn inside the bubble has to fit. r√2, minus a hair so a border
  /// stroke does not clip it.
  double get contentExtent => radius * math.sqrt2 - 2;

  /// A public party's bubble, sized by [count].
  ///
  /// `sqrt` and saturating, for the same reason the pill's width was: the
  /// count has no upper bound, the map draws up to 200 of these, and a linear
  /// scale turns one popular party into an occluding blob.
  factory MpDropGeometry.forCount(int count) {
    final pop = math.max(0, count).toDouble();
    final t = math.min(1.0, math.sqrt(pop) / math.sqrt(saturatesAt));
    return MpDropGeometry._(
      radius: minRadius + (maxRadius - minRadius) * t,
      isPrivate: false,
    );
  }

  /// A private party's bubble. Fixed, and fixed at the CEILING of the public
  /// scale rather than at some fourth magnitude of its own.
  ///
  /// Sitting at the top of the range is the point: a private bubble is never
  /// smaller than any public one, so no observer can read "this private party
  /// is a quiet one" off its silhouette. A distinct in-between size would be
  /// constant too, but it would invite exactly that reading.
  factory MpDropGeometry.private() =>
      const MpDropGeometry._(radius: maxRadius, isPrivate: true);

  /// The bubble [pin] draws at when the clock reads [now].
  ///
  /// **The private branch is taken BEFORE the count is read, and that ordering
  /// is the control.** "Fixed size for private parties" implemented as
  /// `size = isPrivate ? kFixed : f(count)` is a size that does not currently
  /// depend on the count; implemented as a branch that never reaches
  /// [MapPartyPin.attendeeCountAt] at all, it is a size that *cannot*. There
  /// is no expression anywhere on this path with both a private pin and a
  /// count in it, so there is nothing for a later edit to accidentally
  /// re-enable. `mp_drop_shape_golden_test.dart` asserts identity across
  /// counts of 0, 1, 99, 100 and 5000.
  ///
  /// Note this reads the count through [MapPartyPin.attendeeCountAt] rather
  /// than a stored field, so a public bubble re-sizes when a party goes live
  /// and the tense flips from `interested` to `going` — no refetch, no server
  /// flag.
  factory MpDropGeometry.forPin(MapPartyPin pin, DateTime now) {
    if (pin.isPrivate) return MpDropGeometry.private();
    return MpDropGeometry.forCount(pin.attendeeCountAt(now));
  }

  /// The outline, in the marker box's own coordinates.
  ///
  /// One continuous subpath, deliberately: the private border is dashed by
  /// walking [PathMetric] along it, and a shape assembled from several
  /// subpaths restarts the dash pattern at every seam.
  Path build() {
    final d = radius * tipRatio;
    // acos is safe: tipRatio > 1, so radius/d < 1 by construction.
    final theta = math.acos(radius / d);

    // Angles from +x, growing clockwise on screen (y is down). The body's
    // tangent points sit at π/2 ± θ; sweeping the long way round from one to
    // the other traverses the top and leaves the bottom wedge for the flanks.
    final bodyStart = math.pi / 2 + theta;
    final bodySweep = 2 * math.pi - 2 * theta;

    // The arc ends on the RIGHT tangent point and closes back to the left one.
    final right = center + Offset(radius * math.cos(bodyStart + bodySweep),
        radius * math.sin(bodyStart + bodySweep));
    final left = center + Offset(radius * math.cos(bodyStart), radius * math.sin(bodyStart));

    // The apex arc: a circle whose lowest point IS the tip, so the anchor is
    // exact rather than approached.
    final apexR = radius * apexRatio;
    final apexCenter = Offset(center.dx, center.dy + d - apexR);
    final psi = apexContactAngle;
    final apexRight = apexCenter + Offset(apexR * math.sin(psi), apexR * math.cos(psi));
    final apexLeft = apexCenter + Offset(-apexR * math.sin(psi), apexR * math.cos(psi));

    // Unit tangents at the two joins, both pointing the way the outline
    // travels (down the right flank, through the apex, up the left).
    final bodyTangent = Offset(-math.cos(theta), math.sin(theta));
    final apexTangent = Offset(-math.cos(psi), math.sin(psi));

    final reach = (apexRight - right).distance * flankTension;

    return Path()
      ..addArc(Rect.fromCircle(center: center, radius: radius), bodyStart, bodySweep)
      // Right flank: leaves the body along its tangent, arrives at the apex
      // arc along the apex's.
      ..cubicTo(
        right.dx + bodyTangent.dx * reach,
        right.dy + bodyTangent.dy * reach,
        apexRight.dx - apexTangent.dx * reach,
        apexRight.dy - apexTangent.dy * reach,
        apexRight.dx,
        apexRight.dy,
      )
      // The rounded apex itself, swept through straight-down (π/2).
      ..arcTo(
        Rect.fromCircle(center: apexCenter, radius: apexR),
        math.pi / 2 - psi,
        2 * psi,
        false,
      )
      // Left flank: the mirror, traversed in the opposite sense — so the
      // tangents are negated rather than re-derived.
      ..cubicTo(
        apexLeft.dx + Offset(apexTangent.dx, -apexTangent.dy).dx * reach,
        apexLeft.dy + Offset(apexTangent.dx, -apexTangent.dy).dy * reach,
        left.dx - Offset(bodyTangent.dx, -bodyTangent.dy).dx * reach,
        left.dy - Offset(bodyTangent.dx, -bodyTangent.dy).dy * reach,
        left.dx,
        left.dy,
      )
      ..close();
  }
}

/// Paints a bubble: fill, border, and the glow that separates it from the dark
/// basemap.
///
/// The private/public distinction is carried by the BORDER — dashed for
/// private, solid for public — exactly as it was on the pill and the teardrop,
/// so the one thing a reader already knows how to decode survives the
/// reshaping. It is deliberately not carried by size: size is the attendance
/// channel for public parties and is constant for private ones, so overloading
/// it would make two facts share one signal.
class MpDropPainter extends CustomPainter {
  const MpDropPainter({
    required this.geometry,
    required this.accent,
    required this.fill,
    this.borderWidth = 1.75,
    this.glowBlur = 16,
  });

  final MpDropGeometry geometry;
  final Color accent;
  final Color fill;
  final double borderWidth;
  final double glowBlur;

  /// Dash geometry for the private outline, in logical pixels. Walked along
  /// the path with [PathMetric] rather than approximated per segment, so the
  /// dashes stay evenly spaced around the curve and through both flank joins
  /// instead of resetting at each one.
  static const double _dash = 5;
  static const double _gap = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    final path = geometry.build();

    canvas.drawPath(
      path,
      Paint()
        ..color = accent.withValues(alpha: 0.55)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, glowBlur / 2),
    );

    canvas.drawPath(path, Paint()..color = fill);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeCap = StrokeCap.round
      ..color = accent;

    if (geometry.isPrivate) {
      canvas.drawPath(_dashed(path), stroke);
    } else {
      canvas.drawPath(path, stroke);
    }
  }

  Path _dashed(Path source) {
    final out = Path();
    for (final PathMetric metric in source.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + _dash, metric.length);
        out.addPath(metric.extractPath(distance, next), Offset.zero);
        distance = next + _gap;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(covariant MpDropPainter old) =>
      old.geometry.radius != geometry.radius ||
      old.geometry.isPrivate != geometry.isPrivate ||
      old.accent != accent ||
      old.fill != fill ||
      old.borderWidth != borderWidth ||
      old.glowBlur != glowBlur;
}
