import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// PUBLIC / PRIVATE pill badge, Greek by default and English on request.
///
/// The [english] flag exists because this badge is shared by seven surfaces
/// and only the map tab has been translated. Threading a real locale through
/// every call site is a localisation layer this app does not have yet -- the
/// same reason `english_date.dart` is a deliberate near-duplicate of
/// `greek_date.dart` rather than one file with a locale argument. When that
/// layer arrives, this flag and those two files collapse into it together.
///
/// Defaulted to Greek so the six call sites nobody asked about cannot change
/// by accident.
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

  /// Renders PRIVATE/PUBLIC instead of ΙΔΙΩΤΙΚΟ/ΔΗΜΟΣΙΟ. Opt-in, per call site.
  final bool english;

  const PrivacyBadge({
    super.key,
    required this.isPrivate,
    this.suffix,
    this.fontSize = 8,
    this.english = false,
  });

  bool get _private => isPrivate;

  @override
  Widget build(BuildContext context) {
    final label = (english
            ? (_private ? 'PRIVATE' : 'PUBLIC')
            : (_private ? 'ΙΔΙΩΤΙΚΟ' : 'ΔΗΜΟΣΙΟ')) +
        (suffix != null ? ' · $suffix' : '');
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
