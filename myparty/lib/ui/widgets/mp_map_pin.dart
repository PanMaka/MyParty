import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/map_party_pin.dart';
import '../theme/app_theme.dart';
import 'dashed_border.dart';
import 'diagonal_placeholder.dart';

/// The three sizes a map pin comes in. Which one a party gets is decided by
/// its attendee count *at the moment of the rebuild* — see [MpPinMetrics].
enum MpPinTier { small, medium, large }

/// The counts at which a pin steps up a tier. Public because the tests place
/// pins either side of these boundaries, and a test that restated the numbers
/// would keep passing after somebody moved them.
const int mpPinMediumFrom = 25;
const int mpPinLargeFrom = 100;

/// Every dimension a pin draws at, for one tier and one count.
///
/// This is the *single* source of the pin's size. [MapScreen] needs it too —
/// a `Marker` declares its own width and height, and a box that disagrees
/// with the pill inside it clips the pill — so both sides read this class,
/// from one clock reading per frame rather than two. Two independent
/// `DateTime.now()` calls straddling a party's start time is not a
/// hypothetical: it is what the previous version did, once in the marker and
/// once inside the widget.
@immutable
class MpPinMetrics {
  const MpPinMetrics._({
    required this.tier,
    required this.width,
    required this.height,
    required this.thumb,
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
  final double width;
  final double height;
  final double thumb;
  final double radius;
  final EdgeInsets padding;
  final double gap;
  final double titleSize;
  final double metaSize;
  final double dot;
  final double borderWidth;
  final double glowBlur;

  /// Vertical slack above the pill for its glow and drop shadow. The live
  /// pulse ring overshoots far past this and is allowed to — it paints with
  /// `Clip.none` — but the shadow has to stay inside the marker box.
  static const double pulseHeadroom = 6;

  double get boxHeight => height + pulseHeadroom;

  /// The width left to the title and count column once the thumbnail, the gap
  /// and the horizontal padding have taken their share.
  ///
  /// The label row is laid out inside this and nothing else, which is why it
  /// has to be allowed to ellipsize: [width] grows by at most a couple of
  /// dozen pixels across the whole range of a count that has no upper bound.
  /// This is smallest — and so the truncation risk is highest — at
  /// [MpPinTier.small].
  double get labelWidth => width - padding.horizontal - thumb - gap;

  /// The metrics for a party with [count] people attached to it.
  ///
  /// Width still grows *within* a tier, so two large parties are not the same
  /// pin — but it grows on a `sqrt` and saturates, because the map has to stay
  /// readable at the RPC's 200-pin cap and a linear scale would not.
  factory MpPinMetrics.forCount(int count) {
    final pop = math.max(0, count).toDouble();

    if (pop >= mpPinLargeFrom) {
      return MpPinMetrics._(
        tier: MpPinTier.large,
        width: 132 + math.min(26, math.sqrt(pop) * 1.9),
        height: 56,
        thumb: 44,
        radius: 14,
        padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
        gap: 8,
        titleSize: 12,
        metaSize: 9.5,
        dot: 6,
        borderWidth: 1.75,
        glowBlur: 18,
      );
    }

    if (pop >= mpPinMediumFrom) {
      return MpPinMetrics._(
        tier: MpPinTier.medium,
        width: 112 + math.min(20, math.sqrt(pop) * 2.0),
        height: 46,
        thumb: 34,
        radius: 12,
        padding: const EdgeInsets.fromLTRB(5, 5, 8, 5),
        gap: 7,
        titleSize: 10.5,
        metaSize: 8.5,
        dot: 5,
        borderWidth: 1.5,
        glowBlur: 14,
      );
    }

    return MpPinMetrics._(
      tier: MpPinTier.small,
      width: 96 + math.min(14, math.sqrt(pop) * 2.9),
      height: 38,
      thumb: 26,
      radius: 10,
      padding: const EdgeInsets.fromLTRB(4, 4, 7, 4),
      gap: 6,
      titleSize: 9.5,
      metaSize: 7.5,
      dot: 4,
      borderWidth: 1.25,
      glowBlur: 11,
    );
  }

  /// The metrics [pin] draws at when the clock reads [now].
  ///
  /// Goes through [MapPartyPin.attendeeCountAt] rather than a stored number,
  /// so the tier follows the tense: a party sized by its *interested* count
  /// before it starts is re-tiered on its *going* count the moment it does,
  /// with no new fetch and no server flag involved.
  factory MpPinMetrics.forPin(MapPartyPin pin, DateTime now) =>
      MpPinMetrics.forCount(pin.attendeeCountAt(now));
}

/// A glass-pill map marker for a party pin, sized by its live attendee count,
/// with a pulse ring while the party is actually happening.
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
    final m = MpPinMetrics.forCount(count);
    final accent = pin.isPrivate ? AppColors.pink : AppColors.purple;

    final pill = Container(
      padding: m.padding,
      decoration: BoxDecoration(
        color: const Color(0xFF0E0C14).withValues(alpha: 0.93),
        borderRadius: BorderRadius.circular(m.radius),
        border: pin.isPrivate
            ? null
            : Border.all(color: accent.withValues(alpha: 0.95), width: m.borderWidth),
        boxShadow: [
          BoxShadow(color: accent.withValues(alpha: 0.55), blurRadius: m.glowBlur),
          const BoxShadow(color: Colors.black54, blurRadius: 16, offset: Offset(0, 6)),
        ],
      ),
      child: Row(
        children: [
          SizedBox(
            width: m.thumb,
            height: m.thumb,
            child: DiagonalStripePlaceholder(
              borderRadius: BorderRadius.circular(m.radius - 4),
              colors: pin.isPrivate
                  ? const [Color(0xFF2C1F2A), Color(0xFF20161F)]
                  : const [Color(0xFF2A2247), Color(0xFF1E1836)],
            ),
          ),
          SizedBox(width: m.gap),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                    SizedBox(width: m.gap - 2),
                    // Flexible, because the pill's width is fixed by
                    // MpPinMetrics and this label is not: it is derived from a
                    // count, and the width formula tops out ~26px into every
                    // tier however large that count gets. The exposure is
                    // worst at the SMALL tier, which has the least
                    // `labelWidth` of the three and is therefore where the
                    // test asserts the truncation. A four-digit party
                    // overflows this row on a real handset, and any count at
                    // all overflows it under `flutter test`, where the mono
                    // face is absent and the fallback metrics are far wider.
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
        ],
      ),
    );

    final pulse = _pulse;

    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: m.width,
        height: m.boxHeight,
        child: Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          children: [
            if (pulse != null)
              AnimatedBuilder(
                animation: pulse,
                builder: (context, _) {
                  final t = pulse.value;
                  return Opacity(
                    opacity: (1 - t) * 0.55,
                    child: Transform.scale(
                      scale: 1 + t * 1.4,
                      child: Container(
                        width: m.width,
                        height: m.height,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(m.radius + 1),
                          border: Border.all(color: accent, width: m.borderWidth),
                        ),
                      ),
                    ),
                  );
                },
              ),
            SizedBox(
              width: m.width,
              height: m.height,
              child: pin.isPrivate
                  ? DashedRRectBorder(
                      color: accent,
                      radius: m.radius,
                      strokeWidth: m.borderWidth,
                      child: pill,
                    )
                  : pill,
            ),
          ],
        ),
      ),
    );
  }
}
