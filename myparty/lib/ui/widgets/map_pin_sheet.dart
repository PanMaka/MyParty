import 'package:flutter/material.dart';

import '../../data/party_repository.dart';
import '../../models/feed_post.dart';
import '../../models/map_party_pin.dart';
import '../../utils/greek_date.dart';
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

  Future<void> _loadCover() async {
    if (!widget.pin.hasCover) return;
    try {
      final url = await widget.repository.signedCoverUrl(widget.pin.coverPath);
      if (mounted) setState(() => _coverUrl = url);
    } catch (_) {
      // Swallowed for the reason above: the placeholder is already correct.
      // Rethrowing would take down a sheet whose text is entirely fine.
    }
  }

  @override
  Widget build(BuildContext context) {
    final pin = widget.pin;
    // One clock reading for the whole sheet. `pin.live` and `pin.attendeeCount`
    // are conveniences that each call `DateTime.now()` themselves, so the
    // uses below would be separate readings of the clock — and a party
    // crossing its start time between them would print an interested count
    // under a "μέσα τώρα" label. Same reason [MpMapPin] takes its instant from
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
              const SizedBox(height: 14),
              _counts(live, count),
              const SizedBox(height: 18),
              _action(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(bool live) {
    final pin = widget.pin;
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
                  PrivacyBadge(isPrivate: pin.isPrivate),
                  if (live) ...[
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
    );
  }

  /// 16:9 rather than square: it is a scene, and the same ratio
  /// [ProfilePartyCard] uses, so one party does not change shape between two
  /// screens that can both show it.
  Widget _cover() {
    final pin = widget.pin;
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
    final pin = widget.pin;
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
                ? formatPartyStart(startsAt)
                : formatPartyPast(startsAt),
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
  /// "12 μέσα τώρα" and "34 ενδιαφέρονται" can both be true and both be worth
  /// knowing. The tense still decides which one leads.
  Widget _counts(bool live, int count) {
    final pin = widget.pin;
    final other = live
        ? '${pin.interestedCount} ενδιαφέρονται'
        : '${pin.goingCount} δηλώσαν ότι έρχονται';

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            live ? '$count μέσα τώρα' : '$count ενδιαφέρονται',
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

  /// Still a placeholder, and still says so.
  ///
  /// Nothing in the client writes `rsvps` — the table has all four policies and
  /// `authenticated` holds insert/update/delete (`20260813100309`), so this is
  /// a missing repository method rather than missing schema, and it is its own
  /// phase: an RSVP needs optimistic state, a rollback and a story for the two
  /// counters this sheet is displaying.
  ///
  /// What is NOT a placeholder is the label. `my_rsvp_status` now arrives from
  /// both RPCs, so the button reads the viewer's existing answer back to them
  /// instead of inviting them to repeat it.
  Widget _action() {
    final pin = widget.pin;
    final status = pin.myRsvpStatus;
    final already = status == 'going' || status == 'interested';

    final label = switch (status) {
      'going' => 'Δήλωσες ότι έρχεσαι',
      'interested' => 'Δήλωσες ενδιαφέρον',
      _ => pin.isPrivate ? 'Έρχομαι' : 'Μ’ ενδιαφέρει',
    };

    return SizedBox(
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
            // An answered RSVP drops the gradient for a flat outline: the
            // gradient is a call to action, and repeating it on a decision
            // already taken is what makes a button look unresponsive.
            gradient: already ? null : (pin.isPrivate ? AppColors.pinkGradient : AppColors.purpleGradient),
            color: already ? Colors.white.withValues(alpha: 0.06) : null,
            border: already ? Border.all(color: AppColors.hairline) : null,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                color: already ? AppColors.textAlpha(0.7) : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
