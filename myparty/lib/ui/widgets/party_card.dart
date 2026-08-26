import 'package:flutter/material.dart';

import '../../models/party_list_item.dart';
import '../../state/mp_store.dart' show MpRsvp;
import '../../utils/english_date.dart';
import '../theme/app_theme.dart';
import 'dashed_border.dart';
import 'diagonal_placeholder.dart';
import 'party_detail_sheet.dart';

/// Full party card for the "ALL PARTIES" list — cover, name/host, a
/// public/private accent (solid purple = PUBLIC, dashed red = PRIVATE,
/// mirroring the map pin ring), a live indicator, the attendance line and the
/// RSVP buttons.
///
/// **Driven by a real `parties` row.** It read the const `mpParties` map by
/// string key until Phase 18; every field below now comes from
/// `get_parties_list`, which is what makes server-side sorting possible at all
/// and what unblocked the group-chat and story entry points that had no uuid
/// to hand anybody.
///
/// Three things went when `mpParties` did, and none of them is coming back as
/// written:
///
///  - **The hype bar.** A percentage with no column behind it, decremented by
///    a timer and bumped by taps. What replaced it is the thing it was a
///    picture of: the real counter, labelled by tense — "N interested" before
///    a party starts, "N here now" once it has. Same reason
///    `credibility_score` ships no score.
///  - **`hostSub` / `dist` / `posters`** ("your friend · 3rd party this year",
///    "400 m", "11 people posting"). No column answers any of them. Distance
///    needs a viewer location this list does not have — it is not a spatial
///    query — and is still shown where it IS known, on `MapPinSheet`.
///  - **The mock RSVP state.** The buttons write to `rsvps` now, so tapping
///    one on a private party the server refuses is a visible error rather than
///    a local lie.
class PartyCard extends StatelessWidget {
  const PartyCard({
    super.key,
    required this.item,
    required this.onRsvp,
    this.coverUrl,
  });

  final PartyListItem item;

  /// The signed cover URL, or null for a party whose host uploaded none.
  ///
  /// Passed in rather than signed here: `post-media` and `party-covers` are
  /// private buckets and signing is per-object, so the list signs one batch
  /// for the whole page instead of one request per card.
  final String? coverUrl;

  /// Answers [MpRsvp] for this party, or withdraws the answer when it is
  /// already the current one. The screen owns the write and the refresh — the
  /// card is not the place that decides what a tap costs.
  final ValueChanged<MpRsvp> onRsvp;

  @override
  Widget build(BuildContext context) {
    final accent = item.isPrivate ? AppColors.private : AppColors.purple;
    final rsvp = item.myRsvp;

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
            onTap: () => showPartyDetailSheet(context, item, coverUrl: coverUrl),
            child: SizedBox(
              height: 158,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (coverUrl != null)
                    Image.network(
                      coverUrl!,
                      fit: BoxFit.cover,
                      // A signed URL that 404s or expires between signing and
                      // painting falls back to the placeholder rather than
                      // Flutter's broken-image glyph — same policy the host
                      // post strip applies to its thumbnails.
                      errorBuilder: (_, _, _) => _placeholder(),
                    )
                  else
                    _placeholder(),
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
                          // isLive is the SERVER's answer, not a comparison
                          // done here — it is the same one that put this row
                          // in the list's live group, so the badge and the
                          // ordering cannot disagree.
                          if (item.isLive) ...[
                            Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.pink, shape: BoxShape.circle)),
                            const SizedBox(width: 6),
                          ],
                          Text(formatPartyStartEn(item.startsAt),
                              style: AppTextStyles.mono(size: 11, weight: FontWeight.w700)),
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
                        Text(item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3, height: 1.15)),
                        Text(
                          item.area == null
                              ? '@${item.hostUsername}'
                              : '@${item.hostUsername} · ${item.area}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: AppColors.textAlpha(0.65)),
                        ),
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
                // Attendance, which is PUBLIC-ONLY and absent rather than
                // blanked on a private row. `attendeeLabel` is null exactly
                // when the counters are — the server sends NULL for both on a
                // private party (20260825090051), so there is no number here
                // to forget to hide.
                if (item.attendeeLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      item.attendeeLabel!,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.textAlpha(0.72)),
                    ),
                  ),
                // Group chat, PRIVATE-ONLY (20260825094044). It was a
                // placeholder while this card had no uuid to hand ChatScreen;
                // it has one now.
                if (item.isPrivate)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _reactionPill(
                      onTap: () => openPartyChat(context, item),
                      icon: Icons.forum_outlined,
                      label: 'Group chat',
                    ),
                  ),
                // ONE action on a private party, TWO on a public one.
                //
                // The private button writes 'going' and says "Coming":
                // 20260825090050 makes the rsvps policy refuse an 'interested'
                // row on a private party, so an Interested button here would
                // be an affordance the server answers with a 42501.
                //
                // Tapping the selected button withdraws the answer, which is a
                // DELETE of the row rather than a third enum value.
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: item.acceptsInterested
                      ? Row(
                          children: [
                            Expanded(
                              child: _rsvpButton(
                                label: 'Going',
                                selected: rsvp == MpRsvp.going,
                                gradient: AppColors.purpleGradient,
                                accent: AppColors.purple,
                                onTap: () => onRsvp(MpRsvp.going),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _rsvpButton(
                                label: 'Interested',
                                selected: rsvp == MpRsvp.interested,
                                gradient: AppColors.purpleGradient,
                                accent: AppColors.purple,
                                onTap: () => onRsvp(MpRsvp.interested),
                              ),
                            ),
                          ],
                        )
                      : _rsvpButton(
                          label: 'Coming',
                          selected: rsvp == MpRsvp.going,
                          gradient: AppColors.privateGradient,
                          accent: AppColors.private,
                          onTap: () => onRsvp(MpRsvp.going),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return item.isPrivate
        ? DashedRRectBorder(color: accent, radius: 16, child: body)
        : Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: accent, width: 1.5)),
            child: body,
          );
  }

  Widget _placeholder() => DiagonalStripePlaceholder(
        colors: item.isPrivate
            ? const [Color(0xFF1C1622), Color(0xFF151020)]
            : const [Color(0xFF1D1730), Color(0xFF161126)],
        label: item.isPrivate ? 'private party' : 'no cover yet',
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
