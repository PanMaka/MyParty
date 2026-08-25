import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/mp_party.dart';
import '../../state/mp_store.dart';
import '../theme/app_theme.dart';
import 'diagonal_placeholder.dart';
import 'privacy_badge.dart';

Future<void> showPartyDetailSheet(BuildContext context, String partyId) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PartyDetailSheet(partyId: partyId),
  );
}

class PartyDetailSheet extends StatelessWidget {
  final String partyId;

  const PartyDetailSheet({super.key, required this.partyId});

  @override
  Widget build(BuildContext context) {
    final party = mpParties[partyId]!;
    final store = context.watch<MpStore>();
    final rsvp = store.rsvpFor(partyId);
    final priv = party.isPrivate;

    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
        decoration: const BoxDecoration(
          color: AppColors.sheet,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(context, party),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    _chip(party.time, mono: true),
                    _chip(party.dist),
                    // `crowd` is the attendance line ("24 inside now",
                    // "96 interested"), so a private party gets no chip at all
                    // rather than an empty one. Time and distance stay: they
                    // are properties of the event, not of who is at it.
                    if (!priv) _chip(party.crowd),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Text(party.desc,
                    style: TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.textAlpha(0.75))),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('THE PARTY STORY',
                            style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.5))),
                        // "11 people posting" counts people who are AT the
                        // party. It is a headcount wearing a different noun,
                        // so it goes with the rest of them on a private row.
                        if (!priv)
                          Text(party.posters,
                              style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.4))),
                      ],
                    ),
                    const SizedBox(height: 9),
                    GestureDetector(
                      // Same reason the "Group chat" button below is a
                      // placeholder: this sheet is still driven by the const
                      // `mpParties` map, whose keys are strings like 'taratsa'
                      // rather than uuids. StoryViewerScreen now queries
                      // public.get_party_stories with whatever it is handed, so
                      // passing a mock key would fetch nothing and blame the
                      // network for it. Real entry points into the reel are the
                      // feed's story rail and the picker sheet.
                      onTap: () => _comingSoon(context),
                      child: Row(
                        children: [
                          for (final t in const ['23:41', '00:12'])
                            Expanded(
                              child: Container(
                                margin: const EdgeInsets.only(right: 6),
                                height: 76,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(11),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                                ),
                                child: DiagonalStripePlaceholder(
                                  colors: const [Color(0xFF1D1730), Color(0xFF161126)],
                                  borderRadius: BorderRadius.circular(11),
                                  childAlignment: Alignment.bottomLeft,
                                  child: Text(t, style: AppTextStyles.mono(size: 8, color: AppColors.textAlpha(0.4))),
                                ),
                              ),
                            ),
                          Expanded(
                            child: Container(
                              height: 76,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(11),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                              ),
                              child: DiagonalStripePlaceholder(
                                colors: const [Color(0xFF1D1730), Color(0xFF161126)],
                                borderRadius: BorderRadius.circular(11),
                                child: const Text('+9', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                child: Row(
                  children: [
                    ClipOval(
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: DiagonalStripePlaceholder(
                          colors: const [Color(0xFF2E1F28), Color(0xFF241820)],
                        ),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(party.host, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                          Text(party.hostSub, style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.45))),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      onPressed: () => _comingSoon(context),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                        foregroundColor: AppColors.text,
                      ),
                      child: const Text('Profile', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 26),
                child: Column(
                  children: [
                    // One answer on a private party, two on a public one --
                    // the same rule PartyCard and MapPinSheet apply, for the
                    // same reason: the rsvps policy refuses 'interested' on a
                    // private party (20260825090050).
                    if (priv)
                      _cta(
                        label: 'Coming',
                        selected: rsvp == MpRsvp.going,
                        gradient: AppColors.privateGradient,
                        accent: AppColors.private,
                        onTap: () => store.setRsvp(partyId, MpRsvp.going),
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: _cta(
                              label: 'Going',
                              selected: rsvp == MpRsvp.going,
                              gradient: AppColors.purpleGradient,
                              accent: AppColors.purple,
                              onTap: () => store.setRsvp(partyId, MpRsvp.going, hypeBumpOnJoin: 6),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _cta(
                              label: 'Interested',
                              selected: rsvp == MpRsvp.interested,
                              gradient: AppColors.purpleGradient,
                              accent: AppColors.purple,
                              onTap: () => store.setRsvp(partyId, MpRsvp.interested, hypeBumpOnJoin: 3),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            // This sheet is still driven by the const
                            // `mpParties` map, whose keys are strings like
                            // 'taratsa' rather than uuids — the same reason
                            // Phase 4 wired the report action into MapPinSheet
                            // and not here. ChatScreen now needs a real
                            // parties.id, so this button stays a placeholder
                            // until PartyDetailSheet itself ships real.
                            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Coming soon'),
                                behavior: SnackBarBehavior.floating,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                              backgroundColor: Colors.white.withValues(alpha: 0.06),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                              foregroundColor: AppColors.text,
                            ),
                            child: const Text('Group chat', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _comingSoon(context),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                              backgroundColor: Colors.white.withValues(alpha: 0.06),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                              foregroundColor: AppColors.text,
                            ),
                            child: const Text('Directions', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(party.note,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.35))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cover(BuildContext context, MpParty party) {
    return SizedBox(
      height: 196,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DiagonalStripePlaceholder(
            colors: party.isPrivate
                ? const [Color(0xFF221A2A), Color(0xFF191320)]
                : const [Color(0xFF1F1936), Color(0xFF171229)],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            label: party.imgLabel,
          ),
          Container(
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [AppColors.sheet, Colors.transparent],
                stops: [0.03, 0.75],
              ),
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), shape: BoxShape.circle),
                child: const Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: Row(
              children: [
                PrivacyBadge(
                  isPrivate: party.isPrivate,
                  suffix: party.isPrivate ? 'INVITE ONLY' : null,
                  fontSize: 9,
                  english: true,
                ),
                if (party.live) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('NOW', style: AppTextStyles.mono(size: 9)),
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(party.name,
                    style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.1)),
                const SizedBox(height: 4),
                Text(party.sub, style: TextStyle(fontSize: 12.5, color: AppColors.textAlpha(0.68))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, {bool mono = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(10)),
      child: mono
          ? Text(text, style: AppTextStyles.mono(size: 11.5, weight: FontWeight.w600))
          : Text(text, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500)),
    );
  }
}

/// One RSVP answer in the sheet's footer, lit when it is the viewer's current
/// one. Mirrors PartyCard's `_rsvpButton` at sheet scale.
///
/// Tapping the lit one withdraws the answer -- a DELETE of the row, not a
/// third enum value.
Widget _cta({
  required String label,
  required bool selected,
  required Gradient gradient,
  required Color accent,
  required VoidCallback onTap,
}) {
  return SizedBox(
    width: double.infinity,
    child: ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        backgroundColor: Colors.transparent,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Ink(
        decoration: BoxDecoration(
          gradient: selected ? null : gradient,
          color: selected ? accent.withValues(alpha: 0.16) : null,
          border: selected ? Border.all(color: accent) : null,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(
            selected ? '$label ✓' : label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    ),
  );
}

void _comingSoon(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Coming soon'), behavior: SnackBarBehavior.floating),
  );
}
