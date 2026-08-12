import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Tappable gradient "hype" progress bar with a label above it.
class HypeBar extends StatelessWidget {
  final int percent;
  final String label;
  final Gradient gradient;
  final VoidCallback? onTap;

  const HypeBar({
    super.key,
    required this.percent,
    required this.label,
    this.gradient = AppColors.purpleGradient,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('HYPE ΤΩΡΑ',
                style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.5))),
            Text(label, style: AppTextStyles.mono(size: 11, weight: FontWeight.w700, color: AppColors.pink)),
          ],
        ),
        const SizedBox(height: 5),
        GestureDetector(
          onTap: onTap,
          child: Container(
            height: 9,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(99),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: (percent.clamp(0, 100)) / 100,
              child: Container(
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(99),
                  boxShadow: [
                    BoxShadow(color: AppColors.pink.withValues(alpha: 0.55), blurRadius: 10),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
