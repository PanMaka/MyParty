import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/mp_party.dart';
import '../../state/mp_store.dart';
import '../theme/app_theme.dart';
import 'dashed_border.dart';
import 'diagonal_placeholder.dart';
import 'hype_bar.dart';
import 'party_detail_sheet.dart';

/// Full party card for the "ΟΛΑ ΤΑ PARTY" list — cover, name/host, a
/// public/private ring badge (solid purple = ΔΗΜΟΣΙΟ, dashed magenta =
/// ΙΔΙΩΤΙΚΟ, mirroring the map pin ring), a live indicator, the shared hype
/// bar and the interest button — same building blocks the party posts used
/// to render inline in the feed.
class PartyCard extends StatelessWidget {
  final String partyId;

  const PartyCard({super.key, required this.partyId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MpStore>();
    final party = mpParties[partyId]!;
    final interested = store.interestedIn(partyId);
    final accent = party.isPrivate ? AppColors.pink : AppColors.purple;

    final body = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accent.withValues(alpha: 0.14), Colors.white.withValues(alpha: 0.03)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => showPartyDetailSheet(context, partyId),
            child: SizedBox(
              height: 158,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DiagonalStripePlaceholder(
                    colors: party.isPrivate
                        ? const [Color(0xFF1C1622), Color(0xFF151020)]
                        : const [Color(0xFF1D1730), Color(0xFF161126)],
                    label: party.imgLabel,
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [AppColors.bg.withValues(alpha: 0.92), Colors.transparent],
                        stops: const [0.42, 1],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 11,
                    left: 11,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(99)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (party.live) ...[
                            Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.pink, shape: BoxShape.circle)),
                            const SizedBox(width: 6),
                          ],
                          Text(party.time, style: AppTextStyles.mono(size: 11, weight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 11,
                    right: 11,
                    bottom: 11,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(party.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3, height: 1.15)),
                        Text(party.host, style: TextStyle(fontSize: 12, color: AppColors.textAlpha(0.65))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 12, 13, 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: HypeBar(
                        percent: store.hypeOf(partyId),
                        label: '${store.hypeOf(partyId)}%',
                        gradient: party.isPrivate ? const LinearGradient(colors: [AppColors.purpleDeep, AppColors.pink]) : AppColors.purpleGradient,
                        onTap: () => store.bump(partyId, 5),
                      ),
                    ),
                    const SizedBox(width: 9),
                    _hypeBumpButton(accent: accent, onTap: () => store.bump(partyId, 5)),
                  ],
                ),
                // The like pill that used to sit here is gone. Likes are a
                // property of a post (`post_likes`), not of a party — there
                // is no parties.like_count in the schema and no phase that
                // adds one, so it was a counter that could only ever stay
                // mock. `MpStore._likes`, which backed it, went with it.
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _reactionPill(
                    onTap: () => showPartyDetailSheet(context, partyId),
                    icon: Icons.chat_bubble_outline,
                    label: '${party.commentCount}',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _interestButton(
                    interested: interested,
                    onLabel: party.isPrivate ? 'Έρχομαι' : 'Μ’ ενδιαφέρει',
                    offLabel: party.isPrivate ? 'Έρχεσαι ✓' : 'Στα events μου ✓',
                    gradient: party.isPrivate ? AppColors.pinkGradient : AppColors.purpleGradient,
                    onTap: () => store.toggleInterest(partyId, hypeBumpOnJoin: 6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return party.isPrivate
        ? DashedRRectBorder(color: accent, radius: 16, child: body)
        : Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: accent, width: 1.5)),
            child: body,
          );
  }
}

Widget _hypeBumpButton({required Color accent, required VoidCallback onTap}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [accent, AppColors.pink]),
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.55), blurRadius: 10)],
      ),
      child: const Icon(Icons.local_fire_department, size: 17, color: Colors.white),
    ),
  );
}

Widget _reactionPill({VoidCallback? onTap, required IconData icon, required String label}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppColors.textAlpha(0.7)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );
}

Widget _interestButton({
  required bool interested,
  required String onLabel,
  required String offLabel,
  required Gradient gradient,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: interested ? null : gradient,
        color: interested ? AppColors.purple.withValues(alpha: 0.16) : null,
        border: interested ? Border.all(color: AppColors.purple) : null,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        interested ? offLabel : onLabel,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: interested ? AppColors.purpleLight : Colors.white),
      ),
    ),
  );
}
