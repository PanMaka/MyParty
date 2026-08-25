import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/mp_party.dart';
import '../../state/mp_store.dart';
import '../theme/app_theme.dart';
import 'dashed_border.dart';
import 'diagonal_placeholder.dart';
import 'hype_bar.dart';
import 'party_detail_sheet.dart';

/// Full party card for the "ALL PARTIES" list — cover, name/host, a
/// public/private ring badge (solid purple = PUBLIC, dashed magenta =
/// PRIVATE, mirroring the map pin ring), a live indicator, the shared hype
/// bar and the interest button — same building blocks the party posts used
/// to render inline in the feed.
///
/// Rendered only by EventsScreen, which is why this file could be translated
/// outright rather than growing PrivacyBadge's opt-in `english` flag.
class PartyCard extends StatelessWidget {
  final String partyId;

  const PartyCard({super.key, required this.partyId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MpStore>();
    final party = mpParties[partyId]!;
    final rsvp = store.rsvpFor(partyId);
    final accent = party.isPrivate ? AppColors.private : AppColors.purple;

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
                // The hype bar is PUBLIC-ONLY, and it is removed rather than
                // blanked. A percentage derived from attendance IS attendance:
                // it moves when people join, so a reader watching it learns the
                // same thing the count would have told them, one derivative
                // removed. The bump button goes with it -- there is nothing
                // left for it to move.
                if (!party.isPrivate)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: HypeBar(
                          percent: store.hypeOf(partyId),
                          label: '${store.hypeOf(partyId)}%',
                          gradient: AppColors.purpleGradient,
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
                // ONE action on a private party, TWO on a public one.
                //
                // The private button writes 'going' and says "Coming":
                // 20260825090050 makes the rsvps policy refuse an 'interested'
                // row on a private party, so an Interested button here would be
                // an affordance the server answers with a 42501.
                //
                // Tapping the selected button withdraws the answer, which is a
                // DELETE of the row rather than a third enum value -- the same
                // already-selected pattern this card has always shown, now with
                // two buttons to be selected between.
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: party.isPrivate
                      ? _rsvpButton(
                          label: 'Coming',
                          selected: rsvp == MpRsvp.going,
                          gradient: AppColors.privateGradient,
                          accent: AppColors.private,
                          onTap: () => store.setRsvp(partyId, MpRsvp.going),
                        )
                      : Row(
                          children: [
                            Expanded(
                              child: _rsvpButton(
                                label: 'Going',
                                selected: rsvp == MpRsvp.going,
                                gradient: AppColors.purpleGradient,
                                accent: AppColors.purple,
                                onTap: () => store.setRsvp(partyId, MpRsvp.going, hypeBumpOnJoin: 6),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _rsvpButton(
                                label: 'Interested',
                                selected: rsvp == MpRsvp.interested,
                                gradient: AppColors.purpleGradient,
                                accent: AppColors.purple,
                                onTap: () => store.setRsvp(partyId, MpRsvp.interested, hypeBumpOnJoin: 3),
                              ),
                            ),
                          ],
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

/// One RSVP answer, lit when it is the viewer's current one.
///
/// [accent] is the PARTY's colour, so a selected answer on a private party
/// reads red rather than borrowing public purple. The selected state is an
/// outline, and an outline in the wrong colour is the one place the privacy
/// signal could quietly disagree with the border drawn around the whole card.
Widget _rsvpButton({
  required String label,
  required bool selected,
  required Gradient gradient,
  required Color accent,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: selected ? null : gradient,
        color: selected ? accent.withValues(alpha: 0.16) : null,
        border: selected ? Border.all(color: accent) : null,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        selected ? '$label ✓' : label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: selected ? AppColors.text : Colors.white,
        ),
      ),
    ),
  );
}
