import 'package:flutter/material.dart';

import '../../models/feed_post.dart';
import '../../models/map_party_pin.dart';
import '../../models/mp_party.dart';
import '../theme/app_theme.dart';
import 'diagonal_placeholder.dart';
import 'privacy_badge.dart';
import 'report_sheet.dart';

/// Lightweight detail sheet for a real Supabase-backed map pin. Only shows
/// what the RPC actually returns — no fabricated host/description/story data.
Future<void> showMapPinSheet(BuildContext context, MapPartyPin pin) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => MapPinSheet(pin: pin),
  );
}

class MapPinSheet extends StatelessWidget {
  final MapPartyPin pin;

  const MapPinSheet({super.key, required this.pin});

  @override
  Widget build(BuildContext context) {
    final type = pin.isPrivate ? MpPartyType.private : MpPartyType.public;
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.sheet,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(13)),
                  child: const DiagonalStripePlaceholder(colors: [Color(0xFF1D1730), Color(0xFF161126)]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(pin.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          PrivacyBadge(type: type),
                          if (pin.live) ...[
                            const SizedBox(width: 6),
                            Text('ΤΩΡΑ', style: AppTextStyles.mono(size: 9, color: AppColors.pinkLight)),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // A party is UGC too, and this sheet — unlike the mock
                // PartyDetailSheet — is backed by a real `parties` row, so
                // pin.id is the uuid `reports.target_id` needs.
                IconButton(
                  onPressed: () => showReportSheet(
                    context,
                    target: ReportTarget.party,
                    targetId: pin.id,
                  ),
                  icon: Icon(Icons.more_horiz, size: 20, color: AppColors.textAlpha(0.5)),
                  tooltip: 'Αναφορά',
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(10)),
              child: Text(
                pin.live ? '${pin.attendeeCount} μέσα τώρα' : '${pin.attendeeCount} ενδιαφέρονται',
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Έρχεται σύντομα'), behavior: SnackBarBehavior.floating),
                  );
                },
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Ink(
                  decoration: BoxDecoration(
                    gradient: pin.isPrivate ? AppColors.pinkGradient : AppColors.purpleGradient,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(pin.isPrivate ? 'Έρχομαι' : 'Μ’ ενδιαφέρει',
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
