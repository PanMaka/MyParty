import 'package:flutter/material.dart';

import '../../data/party_repository.dart';
import '../../models/feed_post.dart';
import '../../models/map_party_pin.dart';
import '../../state/mp_store.dart';
import '../../state/rsvp_changes.dart';
import '../../utils/english_date.dart';
import '../theme/app_theme.dart';
import 'diagonal_placeholder.dart';
import 'privacy_badge.dart';
import 'report_sheet.dart';

/// The party sheet, opened by tapping a map pin OR a search hit.
///
/// **One sheet, deliberately, and both callers pass the same two arguments.**
/// `search_parties` returns `lat`/`lon` precisely so a hit becomes a
/// [MapPartyPin] and lands here, which is what makes the report action, the
/// live count and now the whole body identical from either screen. That only
/// holds because both RPCs carry the same columns — `description` and
/// `my_rsvp_status` were map-only until `20260824094606`, and
/// `20_party_search.test.sql` asserts the parity structurally so they cannot
/// drift apart again.
///
/// [repository] is required rather than optional so a caller cannot silently
/// opt out of covers: `party-covers` is private, the path in the payload is a
/// storage key and not a URL, and a sheet with no way to sign it would draw
/// the placeholder forever with nothing to say why.
Future<void> showMapPinSheet(
  BuildContext context,
  MapPartyPin pin, {
  required PartyRepository repository,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => MapPinSheet(pin: pin, repository: repository),
  );
}

class MapPinSheet extends StatefulWidget {
  const MapPinSheet({super.key, required this.pin, required this.repository});

  final MapPartyPin pin;
  final PartyRepository repository;

  @override
  State<MapPinSheet> createState() => _MapPinSheetState();
}

class _MapPinSheetState extends State<MapPinSheet> {
  /// The pin as the sheet currently shows it — [MapPinSheet.pin] plus any RSVP
  /// the viewer has answered here, applied optimistically by
  /// [MapPartyPin.withRsvp] so the button and the counts move on the tap.
  late MapPartyPin _pin = widget.pin;

  /// An RSVP write in flight. Taps are refused meanwhile: a second answer
  /// sent before the first lands would compute its `current` from an
  /// optimistic state the server has not confirmed yet.
  bool _saving = false;

  /// The signed cover URL, or null for "no cover, or it would not sign".
  ///
  /// Both collapse to the same rendering on purpose — the placeholder — so
  /// there is no error state to design for a picture. A cover that fails to
  /// sign is the same experience as a host who never uploaded one.
  String? _coverUrl;

  @override
  void initState() {
    super.initState();
    _loadCover();
  }

  /// A new pin from the caller replaces whatever was answered locally: it is
  /// fresher than the optimistic copy, which only stood in for the server.
  @override
  void didUpdateWidget(MapPinSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.pin, widget.pin)) _pin = widget.pin;
  }

  Future<void> _loadCover() async {
    if (!_pin.hasCover) return;
    try {
      final url = await widget.repository.signedCoverUrl(_pin.coverPath);
      if (mounted) setState(() => _coverUrl = url);
    } catch (_) {
      // Swallowed for the reason above: the placeholder is already correct.
      // Rethrowing would take down a sheet whose text is entirely fine.
    }
  }

  @override
  Widget build(BuildContext context) {
    final pin = _pin;
    // One clock reading for the whole sheet. `pin.live` and `pin.attendeeCount`
    // are conveniences that each call `DateTime.now()` themselves, so the
    // uses below would be separate readings of the clock — and a party
    // crossing its start time between them would print an interested count
    // under a "here now" label. Same reason [MpMapPin] takes its instant from
    // its parent rather than reading one per field.
    final now = DateTime.now();
    final live = pin.liveAt(now);
    final count = pin.attendeeCountAt(now);

    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.sheet,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        // Capped and scrollable: a description is host-written free text with
        // no length the client controls, and an unbounded Column in a modal
        // sheet overflows rather than scrolling.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(live),
              const SizedBox(height: 14),
              _cover(),
              const SizedBox(height: 14),
              _facts(),
              if (pin.description != null && pin.description!.trim().isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  pin.description!,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.45,
                    color: AppColors.textAlpha(0.82),
                  ),
                ),
              ],
              // Omitted entirely for a private party — not rendered as a
              // blank row, not rendered as "0". `count` is null there because
              // the server sent no number (20260825090051), so there is
              // nothing to lay out and the CTA moves up to close the gap.
              if (count != null) ...[
                const SizedBox(height: 14),
                _counts(live, count),
              ],
              const SizedBox(height: 18),
              _action(),
              const SizedBox(height: 8),
              _directions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(bool live) {
    final pin = _pin;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(pin.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 5),
              Row(
                children: [
                  PrivacyBadge(isPrivate: pin.isPrivate, english: true),
                  if (live) ...[
                    const SizedBox(width: 6),
                    Text('LIVE', style: AppTextStyles.mono(size: 9, color: AppColors.pinkLight)),
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
          tooltip: 'Report',
        ),
      ],
    );
  }

  /// 16:9 rather than square: it is a scene, and the same ratio
  /// [ProfilePartyCard] uses, so one party does not change shape between two
  /// screens that can both show it.
  Widget _cover() {
    final pin = _pin;
    final placeholder = DiagonalStripePlaceholder(
      colors: pin.isPrivate
          ? const [Color(0xFF2C1F2A), Color(0xFF20161F)]
          : const [Color(0xFF2A2247), Color(0xFF1E1836)],
    );
    final url = _coverUrl;

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: url == null
            ? placeholder
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
                loadingBuilder: (_, child, progress) => progress == null ? child : placeholder,
              ),
      ),
    );
  }

  /// When, where and who — the three things the pin stopped saying when the
  /// label became a bare number.
  ///
  /// Each row is omitted when its column is null rather than rendered empty:
  /// `starts_at` is the only one of the three that is non-null in the schema,
  /// and a blank row reads as a field that failed to load rather than one
  /// nobody filled in.
  Widget _facts() {
    final pin = _pin;
    final startsAt = pin.startsAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (startsAt != null)
          _factRow(
            Icons.schedule,
            // The same two stamps the rest of the app uses, chosen by tense —
            // a past party is being identified, not attended, so it gets the
            // year and not the clock time.
            startsAt.isAfter(DateTime.now())
                ? formatPartyStartEn(startsAt)
                : formatPartyPastEn(startsAt),
          ),
        if (pin.area != null) ...[
          const SizedBox(height: 7),
          _factRow(Icons.place_outlined, pin.area!),
        ],
        if (pin.hostUsername != null) ...[
          const SizedBox(height: 7),
          _factRow(Icons.person_outline, '@${pin.hostUsername}'),
        ],
      ],
    );
  }

  Widget _factRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 15, color: AppColors.textAlpha(0.45)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.78)),
          ),
        ),
      ],
    );
  }

  /// Both counters, not just the tense-appropriate one.
  ///
  /// The pin shows one number because it has room for one; the sheet is where
  /// both are worth knowing. The tense still decides which one leads.
  ///
  /// They OVERLAP, and did not always. Since 20260826093437 `interested_count`
  /// includes everyone going, so "12 here now" alongside "46 interested" means
  /// 46 people of whom 12 have arrived — not 58. Nothing here adds them and
  /// nothing should; if this ever grows a total, it is `interestedCount`
  /// alone.
  /// PUBLIC parties only. [count] is non-null by the caller's guard, and the
  /// two counters it reads alongside are non-null for the same reason: the
  /// server nulls all three together or none of them.
  Widget _counts(bool live, int count) {
    final pin = _pin;
    final other = live
        ? '${pin.interestedCount} interested'
        : '${pin.goingCount} going';

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            live ? '$count here now' : '$count interested',
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            other,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.5)),
          ),
        ),
      ],
    );
  }

  /// Writes the viewer's answer through [PartyRepository.setRsvp].
  ///
  /// Optimistic: the button and both counts move on the tap, and roll back if
  /// the write fails. The sheet stays open so the viewer sees it take. On
  /// success the change is published on [rsvpChanges], which is what makes
  /// the map refetch its pins and MY PARTIES reload — neither tab rebuilds on
  /// its own, they live in an IndexedStack.
  Future<void> _answer(MpRsvp status) async {
    if (_saving) return;
    final before = _pin;
    final current = parseRsvpStatus(before.myRsvpStatus);
    final withdrawing = current == status;
    final next = withdrawing ? null : status;

    setState(() {
      _saving = true;
      _pin = before.withRsvp(next?.name);
    });

    try {
      await widget.repository.setRsvp(
        partyId: before.id,
        status: status,
        current: current,
      );
      rsvpChanges.value = RsvpChange(partyId: before.id, status: next);
    } catch (_) {
      if (!mounted) return;
      setState(() => _pin = before);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That did not save.'), behavior: SnackBarBehavior.floating),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// How many buttons there are, what they say, and which one is lit are all
  /// decided here from `is_private` and `my_rsvp_status`, both of which
  /// arrive from either RPC.
  ///
  /// PUBLIC: two answers, and the viewer can switch between them — which is a
  /// plain `update rsvps set status`, the case the counter trigger's UPDATE
  /// branch has always handled in one delta.
  ///
  /// PRIVATE: one answer, 'going', wearing the word "Coming". Not a UI
  /// preference — 20260825090050 makes the rsvps policy REFUSE an 'interested'
  /// row on a private party, so a second button here would be an affordance
  /// the server answers with a 42501.
  Widget _action() {
    final pin = _pin;
    final status = pin.myRsvpStatus;

    if (pin.isPrivate) {
      return _rsvpButton(
        label: status == 'going' ? 'You are coming ✓' : 'Coming',
        selected: status == 'going',
        gradient: AppColors.privateGradient,
        onTap: () => _answer(MpRsvp.going),
      );
    }

    return Row(
      children: [
        Expanded(
          child: _rsvpButton(
            label: status == 'going' ? 'Going ✓' : 'Going',
            selected: status == 'going',
            gradient: AppColors.purpleGradient,
            onTap: () => _answer(MpRsvp.going),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _rsvpButton(
            label: status == 'interested' ? 'Interested ✓' : 'Interested',
            selected: status == 'interested',
            gradient: AppColors.purpleGradient,
            onTap: () => _answer(MpRsvp.interested),
          ),
        ),
      ],
    );
  }

  /// Directions to the party. A PLACEHOLDER: deliberately inert for now —
  /// no snackbar, no navigation — until the maps hand-off is built. This
  /// sheet is the right home for it because it is fed by a spatial query, so
  /// [MapPartyPin.lat]/[MapPartyPin.lng] are already here to hand over (the
  /// Parties-tab sheet's own Directions button has no coordinates to give).
  ///
  /// Secondary styling, under the RSVP answers: it is a utility, not the
  /// sheet's call to action.
  Widget _directions() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () {},
        icon: const Icon(Icons.directions_outlined, size: 18),
        label: const Text('Directions', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 13),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          backgroundColor: Colors.white.withValues(alpha: 0.06),
          foregroundColor: AppColors.text,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }

  /// One RSVP answer. [selected] is the viewer's current one.
  ///
  /// Tapping the selected button is the un-RSVP, and un-RSVP is a DELETE of
  /// the row — there is no third enum value standing for "not going".
  /// `rsvp_status` has exactly two values and 22_private_party_counts_and_rsvp
  /// asserts it stays that way.
  Widget _rsvpButton({
    required String label,
    required bool selected,
    required Gradient gradient,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _saving ? null : onTap,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Ink(
          decoration: BoxDecoration(
            // An answered RSVP drops the gradient for a flat outline: the
            // gradient is a call to action, and repeating it on a decision
            // already taken is what makes a button look unresponsive.
            gradient: selected ? null : gradient,
            color: selected ? Colors.white.withValues(alpha: 0.06) : null,
            border: selected ? Border.all(color: AppColors.hairline) : null,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                color: selected ? AppColors.textAlpha(0.7) : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
