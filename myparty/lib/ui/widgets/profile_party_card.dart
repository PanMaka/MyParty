import 'package:flutter/material.dart';

import '../../models/party_summary.dart';
import '../../utils/greek_date.dart';
import '../theme/app_theme.dart';
import 'diagonal_placeholder.dart';
import 'privacy_badge.dart';

/// One row in the profile's party list.
///
/// Replaces three separate card builders that lived inside `profile_screen`:
/// the ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ card, the ΤΟ ΙΣΤΟΡΙΚΟ ΜΟΥ tile, and the past-public
/// card. They differed in layout for no reason anybody had written down — the
/// underlying row is the same `parties` row every time.
///
/// Everything drawn here is a real column, and everything nullable stays
/// absent rather than defaulted: no area line when `area` is null, no cover
/// when `cover_path` is null or its signed URL has not arrived, and no
/// capacity ratio at all — the prototype's `18/24` needed a denominator most
/// parties do not have.
class ProfilePartyCard extends StatelessWidget {
  const ProfilePartyCard({
    super.key,
    required this.party,
    required this.relationship,
    this.coverUrl,
    this.onTap,
  });

  final PartySummary party;

  /// The one-word answer to "what is this party to me" — "διοργανώνεις" for
  /// something ahead, "διοργάνωσες" for something behind.
  ///
  /// Passed in rather than derived from [party], because the party row does
  /// not know who is looking at it and this widget must not guess. It is also
  /// why there is no enum here: the list is hosted-only today, so an enum with
  /// `going`/`interested` arms would ship two values nothing can produce.
  final String relationship;

  /// A signed `party-covers` URL, or null when there is no cover or it could
  /// not be signed. Both render the placeholder — to a viewer they are the
  /// same thing, and a broken-image glyph is a worse "no cover" than no cover.
  final String? coverUrl;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          color: Colors.white.withValues(alpha: 0.035),
          border: Border.all(color: AppColors.hairline),
        ),
        // Fixed height, which is what lets the cover fill its side.
        // `CrossAxisAlignment.stretch` asks children to match the Row's own
        // height, and a Row in a ListView has none — the card has to bound it
        // or the constraint is infinite. Every text below is maxLines: 1, so
        // the column never wants more than this anyway.
        child: SizedBox(
          height: 92,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 92, child: _cover()),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          PrivacyBadge(isPrivate: party.isPrivate),
                          const Spacer(),
                          Text(
                            relationship,
                            style: AppTextStyles.mono(size: 9, color: AppColors.textAlpha(0.45)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Text(
                        party.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _whenAndWhere(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.5)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Start time, and the neighbourhood when the host wrote one.
  ///
  /// Joined with '·' only when there is something on both sides. A trailing
  /// separator over an absent area would read as a field that failed to load
  /// rather than one nobody filled in — and `parties_area_one_short_line`
  /// guarantees a non-blank single line whenever it is present, so there is no
  /// third "present but empty" case to handle.
  String _whenAndWhere() {
    final when = party.startsAt.isAfter(DateTime.now())
        ? formatPartyStart(party.startsAt)
        : formatPartyPast(party.startsAt);

    return party.hasArea ? '$when · ${party.area}' : when;
  }

  Widget _cover() {
    final placeholder = DiagonalStripePlaceholder(colors: party.placeholderColors);
    final url = coverUrl;
    if (url == null) return placeholder;

    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => placeholder,
      loadingBuilder: (_, child, progress) => progress == null ? child : placeholder,
    );
  }
}
