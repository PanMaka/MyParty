import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/map_party_pin.dart';
import '../theme/app_theme.dart';
import 'dashed_border.dart';
import 'diagonal_placeholder.dart';

/// Computes the pill width for a map pin, scaled by attendee count — mirrors
/// the design's `112 + min(26, sqrt(pop) * 1.9)`.
double mpPinWidth(int pop) => 112 + math.min(26, math.sqrt(math.max(0, pop)) * 1.9);

const double mpPinHeight = 46;

/// A glass-pill map marker for a party pin, with a live pulse ring when the
/// party is currently live.
class MpMapPin extends StatefulWidget {
  final MapPartyPin pin;
  final VoidCallback onTap;

  const MpMapPin({super.key, required this.pin, required this.onTap});

  @override
  State<MpMapPin> createState() => _MpMapPinState();
}

class _MpMapPinState extends State<MpMapPin> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pin = widget.pin;
    final accent = pin.isPrivate ? AppColors.pink : AppColors.purple;
    final width = mpPinWidth(pin.attendeeCount);

    final pill = Container(
      padding: const EdgeInsets.fromLTRB(5, 5, 8, 5),
      decoration: BoxDecoration(
        color: const Color(0xFF0E0C14).withValues(alpha: 0.93),
        borderRadius: BorderRadius.circular(12),
        border: pin.isPrivate ? null : Border.all(color: accent.withValues(alpha: 0.95), width: 1.5),
        boxShadow: [
          BoxShadow(color: accent.withValues(alpha: 0.55), blurRadius: 14),
          const BoxShadow(color: Colors.black54, blurRadius: 16, offset: Offset(0, 6)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
            child: DiagonalStripePlaceholder(
              colors: pin.isPrivate
                  ? const [Color(0xFF2C1F2A), Color(0xFF20161F)]
                  : const [Color(0xFF2A2247), Color(0xFF1E1836)],
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pin.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, height: 1.2),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(color: pin.live ? Colors.white : accent, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      pin.live ? '${pin.attendeeCount} μέσα' : '${pin.attendeeCount} ενδ.',
                      style: AppTextStyles.mono(
                        size: 8.5,
                        weight: FontWeight.w600,
                        color: pin.isPrivate ? AppColors.pinkLight : AppColors.purpleLight,
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

    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: width,
        height: mpPinHeight + 6,
        child: Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          children: [
            if (pin.live)
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = _controller.value;
                  return Opacity(
                    opacity: (1 - t) * 0.55,
                    child: Transform.scale(
                      scale: 1 + t * 1.4,
                      child: Container(
                        width: width,
                        height: mpPinHeight,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(color: accent, width: 1.5),
                        ),
                      ),
                    ),
                  );
                },
              ),
            SizedBox(
              width: width,
              height: mpPinHeight,
              child: pin.isPrivate ? DashedRRectBorder(color: accent, child: pill) : pill,
            ),
          ],
        ),
      ),
    );
  }
}
