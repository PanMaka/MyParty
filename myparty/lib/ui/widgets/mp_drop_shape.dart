import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../models/map_party_pin.dart';

/// The geometry of a map drop — a circle with two tangent lines converging to
/// a point at the party's actual coordinate.
///
/// **The tip is the anchor, and that is the whole reason for the shape.** A
/// rounded-rect pill has no distinguished point, so it has to be positioned by
/// one of its edges and the reader infers the location from the middle of a
/// 96–158px box. A drop says exactly where it means. That only holds if the
/// tip stays on the coordinate as the drop grows, so everything here is
/// measured from [tip] outward rather than from the box.
///
/// **Sides are true tangents, not eyeballed curves.** Given a circle of radius
/// r centred at C and a tip P at distance d from C, the tangent from P touches
/// the circle at an angle θ = acos(r / d) off the C→P axis. Meeting the circle
/// at a tangent is what makes the join invisible; a line drawn to a guessed
/// point on the circle leaves a crease that is obvious at the large sizes and
/// invisible at the small ones, which is the worst way to be wrong.
@immutable
class MpDropGeometry {
  const MpDropGeometry._({required this.radius, required this.isPrivate});

  /// How far the tip sits from the circle's centre, in radii. 2.2 is chosen so
  /// the tangent angle stays shallow enough to read as a drop rather than a
  /// balloon on a string: at 2.2, θ ≈ 63°, so the straight flanks are about a
  /// third of the outline.
  static const double tipRatio = 2.2;

  /// The public size range. The floor is not zero-ish on purpose — a party
  /// with nobody interested still has to be tappable, and 32px across is
  /// already at the bottom of a comfortable touch target.
  static const double minRadius = 16;
  static const double maxRadius = 36;

  /// The count at which the public scale saturates. Beyond this a party is
  /// "as big as the map draws"; the label still carries the exact number.
  static const int saturatesAt = 100;

  final double radius;
  final bool isPrivate;

  /// The marker box. Width is the circle's diameter; height runs from the top
  /// of the circle to the tip.
  double get width => 2 * radius;
  double get height => radius * (1 + tipRatio);

  Offset get center => Offset(radius, radius);
  Offset get tip => Offset(radius, height);

  /// The largest inscribed square inside the circle, which is what any content
  /// drawn inside the drop has to fit. r√2, minus a hair so a border stroke
  /// does not clip it.
  double get contentExtent => radius * math.sqrt2 - 2;

  /// A public party's drop, sized by [count].
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

  /// A private party's drop. Fixed, and fixed at the CEILING of the public
  /// scale rather than at some fourth magnitude of its own.
  ///
  /// Sitting at the top of the range is the point: a private drop is never
  /// smaller than any public one, so no observer can read "this private party
  /// is a quiet one" off its silhouette. A distinct in-between size would be
  /// constant too, but it would invite exactly that reading.
  factory MpDropGeometry.private() =>
      const MpDropGeometry._(radius: maxRadius, isPrivate: true);

  /// The drop [pin] draws at when the clock reads [now].
  ///
  /// **The private branch is taken BEFORE the count is read, and that ordering
  /// is the control.** "Fixed size for private parties" implemented as
  /// `size = isPrivate ? kFixed : f(count)` is a size that does not currently
  /// depend on the count; implemented as a branch that never reaches
  /// [MapPartyPin.attendeeCountAt] at all, it is a size that *cannot*. There
  /// is no expression anywhere on this path with both a private pin and a
  /// count in it, so there is nothing for a later edit to accidentally
  /// re-enable. `mp_drop_shape_test.dart` asserts identity across counts of
  /// 0, 1, 99, 100 and 5000.
  ///
  /// Note this reads the count through [MapPartyPin.attendeeCountAt] rather
  /// than a stored field, so a public drop re-sizes when a party goes live and
  /// the tense flips from `interested` to `going` — no refetch, no server
  /// flag, same property the pill had.
  factory MpDropGeometry.forPin(MapPartyPin pin, DateTime now) {
    if (pin.isPrivate) return MpDropGeometry.private();
    return MpDropGeometry.forCount(pin.attendeeCountAt(now));
  }

  /// The outline, in the marker box's own coordinates.
  Path build() {
    final d = radius * tipRatio;
    // acos is safe: tipRatio > 1, so radius/d < 1 by construction.
    final theta = math.acos(radius / d);

    // Angles measured from +x, growing clockwise on screen (y is down). The
    // tangent points sit at π/2 ± θ; sweeping the long way round from one to
    // the other traverses the top of the circle and leaves the bottom wedge
    // for the flanks.
    final start = math.pi / 2 + theta;
    final sweep = 2 * math.pi - 2 * theta;

    return Path()
      ..addArc(Rect.fromCircle(center: center, radius: radius), start, sweep)
      ..lineTo(tip.dx, tip.dy)
      ..close();
  }
}

/// Paints a drop: fill, border, and the glow that separates it from the dark
/// basemap.
///
/// The private/public distinction is carried by the BORDER — dashed for
/// private, solid for public — exactly as it was on the pill, so the one thing
/// a reader already knows how to decode survives the reshaping. It is
/// deliberately not carried by size: size is the attendance channel for public
/// parties and is constant for private ones, so overloading it would make two
/// facts share one signal.
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
