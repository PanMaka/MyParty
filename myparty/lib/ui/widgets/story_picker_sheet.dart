import 'package:flutter/material.dart';

import '../../models/mp_party.dart';
import '../screens/story_viewer_screen.dart';
import '../theme/app_theme.dart';
import 'diagonal_placeholder.dart';
import 'privacy_badge.dart';

Future<void> showStoryPickerSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const StoryPickerSheet(),
  );
}

/// "Σε ποιο πάρτι ανεβάζεις;" sheet, shown from the Feed "+ Story" button.
class StoryPickerSheet extends StatelessWidget {
  const StoryPickerSheet({super.key});

  static const _options = ['taratsa', 'vinyl'];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 34),
        decoration: const BoxDecoration(
          color: AppColors.sheet,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(99)),
              ),
            ),
            const Text('Σε ποιο πάρτι ανεβάζεις;',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            const SizedBox(height: 4),
            Text(
              'Το story σου μπαίνει στο κοινό story του πάρτι, μαζί με όλων των άλλων.',
              style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.textAlpha(0.5)),
            ),
            const SizedBox(height: 16),
            for (final id in _options) _row(context, mpParties[id]!),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: Colors.white.withValues(alpha: 0.16), style: BorderStyle.solid),
              ),
              child: Center(
                child: Text('Δεν είμαι σε πάρτι — ανέβασε στο προφίλ',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.textAlpha(0.6))),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, MpParty party) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => StoryViewerScreen(partyId: party.id)),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: (party.isPrivate ? AppColors.pink : AppColors.purple).withValues(alpha: party.isPrivate ? 0.1 : 0.09),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: (party.isPrivate ? AppColors.pink : AppColors.purple).withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
                child: const DiagonalStripePlaceholder(colors: [Color(0xFF1C1622), Color(0xFF151020)]),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(party.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    Text(party.posters, style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.5))),
                  ],
                ),
              ),
              PrivacyBadge(type: party.type),
            ],
          ),
        ),
      ),
    );
  }
}
