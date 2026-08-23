import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/map_party_pin.dart';
import '../theme/app_theme.dart';
import 'diagonal_placeholder.dart';
import 'mp_drop_shape.dart';

/// The three sizes a map pin's LABEL comes in. Which one a party gets is
/// decided by its attendee count *at the moment of the rebuild*.
///
/// Note this tiers the chip's typography only. The drop itself is sized
/// continuously by [MpDropGeometry] — a tiered shape would step visibly as a
/// party filled up, and the whole point of the drop is that its size is the
/// attendance channel.
enum MpPinTier { small, medium, large }

/// The counts at which a pin steps up a tier. Public because the tests place
/// pins either side of these boundaries, and a test that restated the numbers
/// would keep passing after somebody moved them.
const int mpPinMediumFrom = 25;
const int mpPinLargeFrom = 100;

/// Every dimension a pin draws at, for one tier and one count.
///
/// A pin is now TWO pieces: a [MpDropGeometry] whose tip sits on the party's
/// coordinate, and a label chip beside it. They are described together here
/// because a `Marker` declares one width and one height up front and nothing
/// clips the child to them — so the box, the drop inside it, the chip beside
/// it and the anchor that positions the whole thing all have to be derived
/// from one object or they drift apart. [MapScreen] reads the same instance
/// this widget does, from one clock reading per frame.
@immutable
class MpPinMetrics {
  const MpPinMetrics._({
    required this.tier,
    required this.drop,
    required this.chipWidth,
    required this.chipHeight,
    required this.radius,
    required this.padding,
    required this.gap,
    required this.titleSize,
    required this.metaSize,
    required this.dot,
    required this.borderWidth,
    required this.glowBlur,
  });

  final MpPinTier tier;

  /// The drop. Sized by the count for a public party and FIXED for a private
  /// one — see [MpDropGeometry.forPin], where the private branch is taken
  /// before the count is read at all.
  final MpDropGeometry drop;

  final double chipWidth;
  final double chipHeight;

  /// The chip's corner radius. The drop has no corners.
  final double radius;

  final EdgeInsets padding;
  final double gap;
  final double titleSize;
  final double metaSize;
  final double dot;
  final double borderWidth;
  final double glowBlur;

  /// Slack above the drop, for when the chip is taller than the circle it is
  /// centred on.
  ///
  /// Nonzero for a small public drop: the chip is 38px tall against a 32px
  /// circle, so it reaches 3px above the drop and the box has to grow to hold
  /// it. Worth stating because the tip is measured from the box's BOTTOM —
  /// `height` is `topPad + drop.height`, not `drop.height` — so dropping this
  /// term moves the anchor by exactly the overhang on precisely the smallest,
  /// most numerous pins.
  double get topPad => math.max(0, chipHeight / 2 - drop.radius);

  double get width => drop.width + gap + chipWidth;
  double get height => topPad + drop.height;

  /// Retained under its old name because [MapScreen] and the tests both speak
  /// it. There is no separate box height any more — the drop's tip IS the
  /// bottom of the box, which is what puts it on the coordinate.
  double get boxHeight => height;

  /// The width left to the title and count column inside the chip.
  ///
  /// The label has to be allowed to ellipsize: the count has no upper bound
  /// and this width does not grow with it — the chip steps by tier and stops.
  /// Smallest, and so most at risk, at [MpPinTier.small].
  double get labelWidth => chipWidth - padding.horizontal;

  /// Where the party actually is, in the marker box's coordinates.
  Offset get tip => Offset(drop.radius, height);

  /// The `Marker.alignment` that lands [tip] on the coordinate.
  ///
  /// flutter_map positions a marker so the point falls at
  /// `(0.5·w·(1−ax), 0.5·h·(1−ay))` inside the box; inverting that gives the
  /// alignment for an arbitrary anchor. It is NOT `Alignment.topCenter` any
  /// more, and could not be: the box is asymmetric now — drop on the left,
  /// chip on the right — so the tip is nowhere near the horizontal centre, and
  /// centring the box would put the coordinate under the label instead of
  /// under the point. It also moves per pin, because the chip's width steps by
  /// tier while the drop's grows continuously.
  Alignment get anchor => Alignment(1 - 2 * tip.dx / width, 1 - 2 * tip.dy / height);

  Rect get dropRect => Rect.fromLTWH(0, topPad, drop.width, drop.height);

  Rect get chipRect => Rect.fromLTWH(
        drop.width + gap,
        topPad + drop.radius - chipHeight / 2,
        chipWidth,
        chipHeight,
      );

  /// The circle at the top of the drop, which is what the thumbnail fills and
  /// what the live pulse rings.
  Rect get circleRect => Rect.fromCircle(
        center: Offset(drop.radius, topPad + drop.radius),
        radius: drop.radius,
      );

  static MpPinTier _tierFor(int count) {
    if (count >= mpPinLargeFrom) return MpPinTier.large;
    if (count >= mpPinMediumFrom) return MpPinTier.medium;
    return MpPinTier.small;
  }

  static MpPinMetrics _chrome(MpPinTier tier, MpDropGeometry drop) {
    switch (tier) {
      case MpPinTier.large:
        return MpPinMetrics._(
          tier: tier,
          drop: drop,
          chipWidth: 108,
          chipHeight: 46,
          radius: 12,
          padding: const EdgeInsets.fromLTRB(9, 6, 9, 6),
          gap: 6,
          titleSize: 12,
          metaSize: 9.5,
          dot: 6,
          borderWidth: 1.75,
          glowBlur: 18,
        );
      case MpPinTier.medium:
        return MpPinMetrics._(
          tier: tier,
          drop: drop,
          chipWidth: 92,
          chipHeight: 42,
          radius: 10,
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
          gap: 5,
          titleSize: 10.5,
          metaSize: 8.5,
          dot: 5,
          borderWidth: 1.5,
          glowBlur: 14,
        );
      case MpPinTier.small:
        return MpPinMetrics._(
          tier: tier,
          drop: drop,
          chipWidth: 76,
          chipHeight: 38,
          radius: 8,
          padding: const EdgeInsets.fromLTRB(7, 4, 7, 4),
          gap: 4,
          titleSize: 9.5,
          metaSize: 7.5,
          dot: 4,
          borderWidth: 1.25,
          glowBlur: 11,
        );
    }
  }

  /// A PUBLIC party's metrics for [count].
  factory MpPinMetrics.forCount(int count) {
    final pop = math.max(0, count);
    return _chrome(_tierFor(pop), MpDropGeometry.forCount(pop));
  }

  /// A PRIVATE party's metrics. Fixed drop, fixed chip, no count anywhere in
  /// the expression — see [MpDropGeometry.forPin].
  ///
  /// The chip is pinned to [MpPinTier.large] rather than tiered, so nothing
  /// about a private pin's *geometry* varies with attendance. The chip still
  /// prints the number as text, which is a deliberate product decision: only
  /// someone who is invited, RSVP'd or hosting can see the pin at all, so the
  /// count is legitimately theirs. Size carries no information; the label
  /// carries all of it, in words.
  factory MpPinMetrics.private() =>
      _chrome(MpPinTier.large, MpDropGeometry.private());

  /// The metrics [pin] draws at when the clock reads [now].
  ///
  /// Private branches first and never reaches [MapPartyPin.attendeeCountAt].
  /// For a public party this goes through that method rather than a stored
  /// number, so the pin follows the tense: sized on *interested* before the
  /// party starts, re-sized on *going* the moment it does, with no new fetch
  /// and no server flag involved.
  factory MpPinMetrics.forPin(MapPartyPin pin, DateTime now) {
    if (pin.isPrivate) return MpPinMetrics.private();
    return MpPinMetrics.forCount(pin.attendeeCountAt(now));
  }
}

/// A map marker for a party: a drop whose tip is on the coordinate and whose
/// size is the attendance, plus a label chip beside it.
class MpMapPin extends StatefulWidget {
  const MpMapPin({super.key, required this.pin, required this.now, required this.onTap});

  final MapPartyPin pin;

  /// The instant this pin is drawn for, supplied by the parent rather than
  /// read here.
  ///
  /// Required, and deliberately not defaulted to `DateTime.now()`: the pin's
  /// size, its label, its count and whether it pulses are four answers that
  /// have to come from one clock reading, and the marker box drawn around it
  /// is a fifth. A default would let a caller reintroduce that split
  /// silently. Passing it in is also what keeps liveness re-derivable — the
  /// parent hands over a fresh instant on every rebuild, so a party that
  /// starts during the 500ms pan debounce goes live on the next one, whereas
  /// a boolean fetched from the server would stay stale until the user moved
  /// the map.
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
    // same instant, so the ring and the label cannot disagree about tense.
    final live = pin.liveAt(widget.now);
    final count = pin.attendeeCountAt(widget.now);
    final m = MpPinMetrics.forPin(pin, widget.now);
    final accent = pin.isPrivate ? AppColors.pink : AppColors.purple;
    final pulse = _pulse;

    // Inset so the drop's own stroke stays visible around it rather than being
    // covered by the artwork it is supposed to enclose.
    final thumb = m.circleRect.deflate(m.borderWidth + 1);

    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: m.width,
        height: m.height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // The pulse rings the CIRCLE, not the whole drop: a ring following
            // the teardrop outline would sweep its tip across the basemap and
            // read as the pin sliding off its own coordinate.
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

            // The drop: glow, fill, and the border that carries the
            // public/private distinction — solid or dashed, exactly as the
            // pill did, so the one thing a reader already knows how to decode
            // survives the reshaping.
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

            Positioned.fromRect(
              rect: thumb,
              child: ClipOval(
                child: DiagonalStripePlaceholder(
                  borderRadius: BorderRadius.circular(thumb.width),
                  colors: pin.isPrivate
                      ? const [Color(0xFF2C1F2A), Color(0xFF20161F)]
                      : const [Color(0xFF2A2247), Color(0xFF1E1836)],
                ),
              ),
            ),

            Positioned.fromRect(
              rect: m.chipRect,
              child: Container(
                padding: m.padding,
                decoration: BoxDecoration(
                  color: const Color(0xFF0E0C14).withValues(alpha: 0.93),
                  borderRadius: BorderRadius.circular(m.radius),
                  border: Border.all(color: accent.withValues(alpha: 0.55), width: 1),
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12, offset: Offset(0, 4))],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pin.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: m.titleSize, fontWeight: FontWeight.w700, height: 1.2),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: m.dot,
                          height: m.dot,
                          decoration: BoxDecoration(
                            color: live ? Colors.white : accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        SizedBox(width: math.max(2, m.gap - 2)),
                        // Flexible, because the chip's width is fixed by
                        // MpPinMetrics and this label is not: it is derived
                        // from a count that has no upper bound, while
                        // `labelWidth` steps by tier and stops. The exposure is
                        // worst at the SMALL tier, which has the least of it
                        // and is therefore where the test asserts the
                        // truncation. A four-digit party overflows this row on
                        // a real handset, and any count at all overflows it
                        // under `flutter test`, where the mono face is absent
                        // and the fallback metrics are far wider.
                        Flexible(
                          child: Text(
                            live ? '$count μέσα' : '$count ενδ.',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.mono(
                              size: m.metaSize,
                              weight: FontWeight.w600,
                              color: pin.isPrivate ? AppColors.pinkLight : AppColors.purpleLight,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
