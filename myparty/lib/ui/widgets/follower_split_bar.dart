import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One horizontal bar split into "follow you" and "don't", for the host
/// dashboard. Followers in [color]; the rest in a neutral, so the one
/// coloured segment is the one the label talks about.
///
/// Identity is never colour alone: both counts are printed beside the bar.
class FollowerSplitBar extends StatelessWidget {
  const FollowerSplitBar({
    super.key,
    required this.label,
    required this.followers,
    required this.nonFollowers,
    this.color = AppColors.purple,
  });

  final String label;
  final int followers;
  final int nonFollowers;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final total = followers + nonFollowers;
    final percent = total == 0 ? 0 : (followers * 100 / total).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(
              total == 0 ? 'No one yet' : '$percent% follow you',
              style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.6)),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 10,
            child: total == 0
                ? Container(color: Colors.white.withValues(alpha: 0.06))
                : Row(
                    children: [
                      if (followers > 0) Expanded(flex: followers, child: Container(color: color)),
                      // The 2px surface gap between the two fills.
                      if (followers > 0 && nonFollowers > 0) const SizedBox(width: 2),
                      if (nonFollowers > 0)
                        Expanded(
                          flex: nonFollowers,
                          child: Container(color: Colors.white.withValues(alpha: 0.18)),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _key(color, '$followers follow you'),
            const SizedBox(width: 14),
            _key(Colors.white.withValues(alpha: 0.18), '$nonFollowers don’t'),
          ],
        ),
      ],
    );
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
          Text(text, style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.6))),
        ],
      );
}
