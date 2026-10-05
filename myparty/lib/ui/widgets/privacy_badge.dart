import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// PUBLIC / PRIVATE pill badge.
///
/// Takes the bool that `parties.is_private` actually is, rather than the
/// `MpPartyType` enum it used to. Every one of the six call sites was already
/// converting a real bool INTO that enum on the way in
/// (`rsvp.isPrivate ? MpPartyType.private : MpPartyType.public`), so the enum
/// was a round trip through the mock model for a value that never came from it
/// — and it kept `models/mp_party.dart` imported by five screens that have no
/// other reason to know the file exists.
class PrivacyBadge extends StatelessWidget {
  final bool isPrivate;
  final String? suffix;
  final double fontSize;

  const PrivacyBadge({
    super.key,
    required this.isPrivate,
    this.suffix,
    this.fontSize = 8,
  });

  bool get _private => isPrivate;

  @override
  Widget build(BuildContext context) {
    final label = (_private ? 'PRIVATE' : 'PUBLIC') + (suffix != null ? ' · $suffix' : '');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        // Red, not pink, since Phase 16b: one colour means private across the
        // map bubble, this badge and the card borders, so a pin and the badge
        // in the sheet it opens cannot disagree. Deliberately NOT
        // AppColors.destructive — see the token's doc comment.
        color: (_private ? AppColors.private : AppColors.purple).withValues(alpha: 0.9),
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
