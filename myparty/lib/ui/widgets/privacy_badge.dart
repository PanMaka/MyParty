import 'package:flutter/material.dart';

import '../../models/mp_party.dart';
import '../theme/app_theme.dart';

/// ΔΗΜΟΣΙΟ / ΙΔΙΩΤΙΚΟ pill badge.
class PrivacyBadge extends StatelessWidget {
  final MpPartyType type;
  final String? suffix;
  final double fontSize;

  const PrivacyBadge({super.key, required this.type, this.suffix, this.fontSize = 8});

  bool get _private => type == MpPartyType.private;

  @override
  Widget build(BuildContext context) {
    final label = (_private ? 'ΙΔΙΩΤΙΚΟ' : 'ΔΗΜΟΣΙΟ') + (suffix != null ? ' · $suffix' : '');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (_private ? AppColors.pink : AppColors.purple).withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_private) ...[
            Icon(Icons.lock, size: fontSize + 2, color: Colors.white),
            const SizedBox(width: 3),
          ],
          Text(label, style: AppTextStyles.mono(size: fontSize, weight: FontWeight.w700)),
        ],
      ),
    );
  }
}
