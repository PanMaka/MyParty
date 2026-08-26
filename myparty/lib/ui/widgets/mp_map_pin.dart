import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/map_party_pin.dart';
import '../theme/app_theme.dart';
import 'mp_drop_shape.dart';

/// Every dimension a pin draws at, for one count.
///
/// A pin is now ONE piece. The label beside it is gone — with the title,
/// area and description stripped, what is left is a short number, and a short
/// number fits inside the shape it describes. That collapses the marker from
/// `drop + gap + chip` to a bubble, and takes [width] from 112px at the old
/// small tier to `2r`.
///
/// The class survives the collapse because a `Marker` still declares one width
/// and one height up front and nothing clips the child to them, so the box,
/// the bubble inside it and the anchor that positions the whole thing all have
/// to be derived from one object or they drift apart. [MapScreen] reads the
/// same instance this widget does, from one clock reading per frame.
@immutable
class MpPinMetrics {
  const MpPinMetrics._({
    required this.drop,
    required this.borderWidth,
    required this.glowBlur,
  });

  /// The bubble. Sized by the count for a public party and FIXED for a private
  /// one — see [MpDropGeometry.forPin], where the private branch is taken
  /// before the count is read at all.
  final MpDropGeometry drop;

  final double borderWidth;
  final double glowBlur;

  /// The box is the bubble, exactly. There is no chip beside it and nothing
  /// overhangs it, so — unlike the teardrop, whose chip could stand taller
  /// than its circle — there is no `topPad` term any more and the tip is the
  /// box's bottom edge by construction.
  double get width => drop.width;
  double get height => drop.height;

  /// Retained under its old name because [MapScreen] and the tests both speak
  /// it. The bubble's apex IS the bottom of the box, which is what puts it on
  /// the coordinate.
  double get boxHeight => height;

  /// Where the party actually is, in the marker box's coordinates.
  Offset get tip => Offset(drop.radius, height);

  /// The `Marker.alignment` that lands [tip] on the coordinate.
  ///
  /// flutter_map positions a marker so the point falls at
  /// `(0.5·w·(1−ax), 0.5·h·(1−ay))` inside the box; inverting that gives the
  /// alignment for an arbitrary anchor.
  ///
  /// This is a constant again — `Alignment(0, -1)` — because the box became
  /// symmetric the moment the chip was deleted. It is still *computed* from
  /// the geometry rather than written down, so that a future shape whose apex
  /// is not at the bottom centre moves the anchor with it instead of silently
  /// lying about where the party is.
  Alignment get anchor => Alignment(1 - 2 * tip.dx / width, 1 - 2 * tip.dy / height);

  Rect get dropRect => Offset.zero & Size(width, height);

  /// The body circle at the top of the bubble, which is what the live pulse
  /// rings and what the number is centred in.
  Rect get circleRect => Rect.fromCircle(center: drop.center, radius: drop.radius);

  /// Chrome that scales off the radius rather than off a tier.
  ///
  /// The three-tier ladder is gone with the chip it sized. It existed to step
  /// a *typography* scale — title, meta, dot, padding — none of which survives
  /// on a pin that draws one number, and a tiered stroke would step visibly on
  /// a shape whose whole point is that it grows continuously.
  static MpPinMetrics _chrome(MpDropGeometry drop) {
    final t = (drop.radius - MpDropGeometry.minRadius) /
        (MpDropGeometry.maxRadius - MpDropGeometry.minRadius);
    return MpPinMetrics._(
      drop: drop,
      borderWidth: 1.25 + 0.75 * t,
      glowBlur: 11 + 9 * t,
    );
  }

  /// A PUBLIC party's metrics for [count].
  factory MpPinMetrics.forCount(int count) =>
      _chrome(MpDropGeometry.forCount(math.max(0, count)));

  /// A PRIVATE party's metrics. Fixed bubble, and no count anywhere in the
  /// expression — see [MpDropGeometry.forPin].
  ///
  /// Note what is NOT here: a font size. The label's type scale depends on how
  /// many digits it has to draw, which is the count, and putting that in the
  /// metrics would put a count back into the private branch. It is computed at
  /// paint time instead — see [labelSizeFor]. Size carries no information;
  /// the number inside carries all of it.
  factory MpPinMetrics.private() => _chrome(MpDropGeometry.private());

  /// The metrics [pin] draws at when the clock reads [now].
  ///
  /// Private branches first and never reaches [MapPartyPin.attendeeCountAt].
  /// For a public party this goes through that method rather than a stored
  /// number, so the pin follows the tense: sized on *interested* before the
  /// party starts, re-sized on *going* the moment it does, with no new fetch
  /// and no server flag involved.
  factory MpPinMetrics.forPin(MapPartyPin pin, DateTime now) {
    if (pin.isPrivate) return MpPinMetrics.private();
    // See MpDropGeometry.forPin: private branches first, and the coalesce
    // below can only ever apply to a public row.
    return MpPinMetrics.forCount(pin.attendeeCountAt(now) ?? 0);
  }

  /// The type size for a label of [digits] glyphs inside a bubble of [radius].
  ///
  /// Stepping down by digit count is not a hedge against overflow — it is what
  /// keeps the number optically the same weight whether it reads `8` or `340`.
  /// The saturation rule does the actual safety work: a three-digit count is
  /// by definition ≥ 100, which is exactly where the radius saturates, so wide
  /// labels only ever appear on the widest bubbles. A small bubble is
  /// guaranteed at most two digits and there is no ellipsis case to handle —
  /// which is why nothing here clips, and why the truncation test the chip
  /// needed is gone rather than ported.
  ///
  /// Four digits is reachable only on a saturated bubble, so it gets the
  /// tightest step.
  ///
  /// It used to say "only by a live party's `going_count`", and 20260826093437
  /// made that false in the safe direction: `interested_count` now includes
  /// everyone going, so it is >= `going_count` on every row and a PRE-live pin
  /// is the one that reaches four digits first. Nothing here needed changing —
  /// the saturation rule is stated in terms of the count, not of which counter
  /// it came from — but the reasoning is no longer what the comment said.
  static double labelSizeFor(double radius, int digits) {
    if (digits >= 4) return radius * 0.48;
    if (digits == 3) return radius * 0.62;
    return radius * 0.80;
  }
}

/// A map marker for a party: a bubble whose apex is on the coordinate, whose
/// size is the attendance, and which carries the count and nothing else.
class MpMapPin extends StatefulWidget {
  const MpMapPin({super.key, required this.pin, required this.now, required this.onTap});

  final MapPartyPin pin;

  /// The instant this pin is drawn for, supplied by the parent rather than
  /// read here.
  ///
  /// Required, and deliberately not defaulted to `DateTime.now()`: the pin's
  /// size, its number and whether it pulses are three answers that have to
  /// come from one clock reading, and the marker box drawn around it is a
  /// fourth. A default would let a caller reintroduce that split silently.
  /// Passing it in is also what keeps liveness re-derivable — the parent hands
  /// over a fresh instant on every rebuild, so a party that starts during the
  /// 500ms pan debounce goes live on the next one, whereas a boolean fetched
  /// from the server would stay stale until the user moved the map.
  final DateTime now;

  final VoidCallback onTap;

  @override
  State<MpMapPin> createState() => _MpMapPinState();
}

class _MpMapPinState extends State<MpMapPin> with TickerProviderStateMixin {
  /// Null unless the party is live *right now*.
  ///
  /// This used to be a `late final` created and repeated in `initState` for
  /// every pin on the map, live or not, even though nothing rendered it
  /// unless `live` was true. That was free while the payload was broken and
  /// no pin could ever be live; with a real count and the 200-pin cap it is
  /// 200 tickers rebuilding every frame to paint nothing.
  AnimationController? _pulse;

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant MpMapPin oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Unconditional: `now` is a fresh instant on every parent rebuild and
    // liveness is derived from it, so there is no guard cheaper than the bool
    // comparison _syncPulse already makes.
    _syncPulse();
  }

  /// Brings the ticker into line with the liveness [MpMapPin.now] implies —
  /// starting one when a party begins, and *disposing* it when a party ends
  /// while its pin is still on screen.
  void _syncPulse() {
    final live = widget.pin.liveAt(widget.now);
    if (live && _pulse == null) {
      _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..repeat();
    } else if (!live && _pulse != null) {
      _pulse!.dispose();
      _pulse = null;
    }
  }

  @override
  void dispose() {
    _pulse?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pin = widget.pin;
    // One reading, three answers. `_syncPulse` asked the same question of the
    // same instant, so the ring and the number cannot disagree about tense.
    final live = pin.liveAt(widget.now);
    final count = pin.attendeeCountAt(widget.now);
    final m = MpPinMetrics.forPin(pin, widget.now);
    final accent = pin.isPrivate ? AppColors.private : AppColors.purple;
    final pulse = _pulse;

    // The bare number, with no unit and no title — for a PUBLIC party. Which
    // of the two counters it is comes from the tense (`going` while live,
    // `interested` before), and the pulse is what tells the reader which tense
    // they are looking at. The exact wording lives in MapPinSheet, one tap
    // away, where there is room to say it.
    //
    // Null for a private party, and the bubble draws a lock instead. That is
    // the last place attendance was still visible on a private pin: the radius
    // has been fixed since the map rework, but the label printed the count
    // regardless, so the number was on screen no matter what the geometry did.
    // With the server no longer sending it (20260825090051) there is nothing
    // to print, and the lock says why rather than leaving an empty bubble.
    final label = count == null ? null : '$count';

    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: m.width,
        height: m.height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // The pulse rings the CIRCLE, not the whole bubble: a ring
            // following the outline would sweep its apex across the basemap
            // and read as the pin sliding off its own coordinate.
            if (pulse != null)
              Positioned.fromRect(
                rect: m.circleRect,
                child: AnimatedBuilder(
                  animation: pulse,
                  builder: (context, _) {
                    final t = pulse.value;
                    return Opacity(
                      opacity: (1 - t) * 0.55,
                      child: Transform.scale(
                        scale: 1 + t * 1.4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: accent, width: m.borderWidth),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

            // The bubble: glow, fill, and the border that carries the
            // public/private distinction — solid or dashed, exactly as the
            // pill and the teardrop did, so the one thing a reader already
            // knows how to decode survives the reshaping.
            Positioned.fromRect(
              rect: m.dropRect,
              child: CustomPaint(
                painter: MpDropPainter(
                  geometry: m.drop,
                  accent: accent,
                  fill: const Color(0xFF0E0C14),
                  borderWidth: m.borderWidth,
                  glowBlur: m.glowBlur,
                ),
              ),
            ),

            // The count, centred in the body circle — or a lock, when there
            // is no count to draw. No Flexible, no ellipsis and no maxLines:
            // the saturation rule means a label wide enough to be a problem
            // can only appear on a bubble already at maximum radius. See
            // MpPinMetrics.labelSizeFor.
            Positioned.fromRect(
              rect: m.circleRect,
              child: Center(
                child: label == null
                    // Same glyph PrivacyBadge uses, so the pin and the badge
                    // in the sheet it opens say private the same way.
                    ? Icon(
                        Icons.lock,
                        size: m.drop.radius * 0.78,
                        color: live ? Colors.white : AppColors.privateLight,
                      )
                    : Text(
                        label,
                        textAlign: TextAlign.center,
                        style: AppTextStyles.mono(
                          size: MpPinMetrics.labelSizeFor(m.drop.radius, label.length),
                          weight: FontWeight.w600,
                          color: live ? Colors.white : AppColors.purpleLight,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
