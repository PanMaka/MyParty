import 'package:flutter/material.dart';

import '../../models/host_party_stats.dart';
import '../theme/app_theme.dart';

/// One horizontal bar split into men / women / non-binary / not specified, for
/// the host dashboard. Shaped like [FollowerSplitBar]: segments with a 2px
/// surface gap, "not specified" in the same neutral as "don't follow you".
///
/// Identity is never colour alone: every category is printed beside the bar
/// with its count and percentage, a zero included.
///
/// A null [mix] is the server withholding a group under three
/// (20261019193257) and renders as "Not enough guests yet". The threshold is
/// not known here and must not be: a client that could compute the mix of a
/// two-person group would only need the server to send it.
class GenderMixBar extends StatelessWidget {
  const GenderMixBar({super.key, required this.label, required this.mix});

  final String label;
  final GenderMix? mix;

  static const notEnough = 'Not enough guests yet';

  static const maleColor = AppColors.purple;
  static const femaleColor = AppColors.pink;
  static const nonBinaryColor = AppColors.purpleLight;
  static final unspecifiedColor = Colors.white.withValues(alpha: 0.18);

  @override
  Widget build(BuildContext context) {
    final mix = this.mix;
    final segments = mix == null
        ? const <(String, int, Color)>[]
        : [
            ('Men', mix.male, maleColor),
            ('Women', mix.female, femaleColor),
            ('Non-binary', mix.nonBinary, nonBinaryColor),
            ('Not specified', mix.unspecified, unspecifiedColor),
          ];
    final percents = percentages([for (final s in segments) s.$2]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Flexible, not a Spacer: "Interested" beside "Not enough guests yet"
        // overflows a narrow phone at a large text scale, and this one wraps.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                mix == null ? notEnough : '${mix.total} guests',
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.6)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 10,
            child: mix == null
                ? Container(color: Colors.white.withValues(alpha: 0.06))
                : Row(children: _fills(segments)),
          ),
        ),
        if (mix != null) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              for (var i = 0; i < segments.length; i++)
                _key(segments[i].$3, '${segments[i].$1} ${segments[i].$2} · ${percents[i]}%'),
            ],
          ),
        ],
      ],
    );
  }

  /// The non-empty segments, with the 2px gap only between two of them.
  List<Widget> _fills(List<(String, int, Color)> segments) {
    final out = <Widget>[];
    for (final (_, count, color) in segments) {
      if (count == 0) continue;
      if (out.isNotEmpty) out.add(const SizedBox(width: 2));
      out.add(Expanded(flex: count, child: Container(color: color)));
    }
    return out;
  }

  /// Whole percentages that add up to exactly 100 (largest remainder), so a
  /// 1/1/1 group reads 34/33/33 rather than 33/33/33. Empty or all-zero input
  /// gives zeros.
  static List<int> percentages(List<int> counts) {
    final total = counts.fold<int>(0, (a, b) => a + b);
    if (total == 0) return [for (final _ in counts) 0];
    final floors = [for (final c in counts) c * 100 ~/ total];
    var left = 100 - floors.fold<int>(0, (a, b) => a + b);
    // Ties go to the larger count, then to the earlier category, so the same
    // mix always prints the same numbers (List.sort is not stable).
    final byRemainder = [for (var i = 0; i < counts.length; i++) i]
      ..sort((a, b) {
        final byRem = (counts[b] * 100 % total).compareTo(counts[a] * 100 % total);
        if (byRem != 0) return byRem;
        final byCount = counts[b].compareTo(counts[a]);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    for (final i in byRemainder) {
      if (left == 0) break;
      floors[i] += 1;
      left -= 1;
    }
    return floors;
  }

  Widget _key(Color swatch, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: swatch, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 5),
          // Flexible so one entry wider than the row wraps instead of
          // overflowing; the Wrap hands each entry the full row width.
          Flexible(child: Text(text, style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.6)))),
        ],
      );
}
