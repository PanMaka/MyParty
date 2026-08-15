import 'package:flutter/material.dart';

import '../../data/party_repository.dart';
import '../../models/mp_party.dart';
import '../../models/rsvp_party.dart';
import '../../utils/greek_date.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/mp_bottom_nav.dart';
import '../widgets/party_card.dart';
import '../widgets/privacy_badge.dart';
import 'chat_screen.dart';
import 'host_wizard_screen.dart';

class EventsScreen extends StatefulWidget {
  final ValueChanged<MpTab>? onNavigate;

  const EventsScreen({super.key, this.onNavigate});

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  final _repository = PartyRepository();
  bool _showAll = true;
  late Future<List<RsvpParty>> _rsvpsFuture;

  @override
  void initState() {
    super.initState();
    _rsvpsFuture = _repository.fetchMyRsvps();
  }

  void _reloadRsvps() {
    setState(() => _rsvpsFuture = _repository.fetchMyRsvps());
  }

  @override
  Widget build(BuildContext context) {
    final allParties = mpParties.values.toList()..sort((a, b) => a.sortKey.compareTo(b.sortKey));

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Τα events μου', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(99)),
                    child: Row(
                      children: [
                        _segment('ΔΙΚΑ ΜΟΥ', !_showAll, () => setState(() => _showAll = false)),
                        _segment('ΟΛΑ ΤΑ PARTY', _showAll, () => setState(() => _showAll = true)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
              child: GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HostWizardScreen())),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
                  decoration: BoxDecoration(
                    gradient: AppColors.brandGradient,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [BoxShadow(color: AppColors.purpleDeep.withValues(alpha: 0.4), blurRadius: 30, offset: const Offset(0, 10))],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.28), borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.add, color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Διοργάνωσε πάρτι', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
                            SizedBox(height: 1),
                            Text('Ένα λινκ αντί για 100 μηνύματα. Κάτω από ένα λεπτό.',
                                style: TextStyle(fontSize: 11.5, color: Color(0xBFFFFFFF))),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: _showAll
                  ? ListView(
                      padding: const EdgeInsets.fromLTRB(14, 16, 14, 96),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 2, bottom: 9),
                          child: Text('ΟΛΑ ΤΑ PARTY', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.6))),
                        ),
                        for (final party in allParties) ...[
                          PartyCard(partyId: party.id),
                          const SizedBox(height: 14),
                        ],
                      ],
                    )
                  : FutureBuilder<List<RsvpParty>>(
                      future: _rsvpsFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(child: CircularProgressIndicator(color: AppColors.purple));
                        }
                        if (snapshot.hasError) {
                          return _errorState();
                        }

                        final now = DateTime.now();
                        final todayEnd = DateTime(now.year, now.month, now.day + 1);
                        final weekEnd = now.add(const Duration(days: 7));
                        final upcoming = snapshot.data!.where((r) => r.startsAt.isAfter(now)).toList()
                          ..sort((a, b) => a.startsAt.compareTo(b.startsAt));

                        final tonight = <RsvpParty>[];
                        final thisWeek = <RsvpParty>[];
                        final later = <RsvpParty>[];
                        for (final rsvp in upcoming) {
                          if (rsvp.startsAt.isBefore(todayEnd)) {
                            tonight.add(rsvp);
                          } else if (rsvp.startsAt.isBefore(weekEnd)) {
                            thisWeek.add(rsvp);
                          } else {
                            later.add(rsvp);
                          }
                        }

                        if (upcoming.isEmpty) return _emptyState(context);

                        return ListView(
                          padding: const EdgeInsets.fromLTRB(14, 16, 14, 96),
                          children: [
                            if (tonight.isNotEmpty) _rsvpSection(context, 'ΑΠΟΨΕ', tonight, live: true),
                            if (thisWeek.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              _rsvpSection(context, 'ΑΥΤΗ ΤΗ ΒΔΟΜΑΔΑ', thisWeek),
                            ],
                            if (later.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              _rsvpSection(context, 'ΑΡΓΟΤΕΡΑ', later),
                            ],
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rsvpSection(BuildContext context, String title, List<RsvpParty> rsvps, {bool live = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 9),
          child: Row(
            children: [
              if (live) ...[
                Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.pink, shape: BoxShape.circle)),
                const SizedBox(width: 7),
              ],
              Text(title, style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.6))),
            ],
          ),
        ),
        Column(
          children: [for (final rsvp in rsvps) _rsvpRow(context, rsvp)],
        ),
      ],
    );
  }

  Widget _rsvpRow(BuildContext context, RsvpParty rsvp) {
    final accent = rsvp.isPrivate ? AppColors.pink : AppColors.purple;
    final crowd = rsvp.goingCount > 0 ? '${rsvp.goingCount} πάνε' : '${rsvp.interestedCount} ενδιαφέρονται';
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: GestureDetector(
        // An RsvpParty is a real `parties` row, and an rsvp is exactly what
        // can_chat_in_party counts as participation — so this row can open
        // the real group chat rather than the "coming soon" placeholder it
        // used to show.
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatScreen(
            partyId: rsvp.partyId,
            partyTitle: rsvp.title,
            isPrivate: rsvp.isPrivate,
            memberCount: rsvp.goingCount,
          ),
        )),
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(15),
            border: Border(
              top: BorderSide(color: accent.withValues(alpha: 0.3)),
              bottom: BorderSide(color: accent.withValues(alpha: 0.3)),
              right: BorderSide(color: accent.withValues(alpha: 0.3)),
              left: BorderSide(color: accent, width: 3),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 62,
                height: 70,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(11)),
                child: DiagonalStripePlaceholder(
                  colors: rsvp.isPrivate ? const [Color(0xFF1C1622), Color(0xFF151020)] : const [Color(0xFF1D1730), Color(0xFF161126)],
                  label: 'cover',
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        PrivacyBadge(type: rsvp.isPrivate ? MpPartyType.private : MpPartyType.public),
                        const SizedBox(width: 5),
                        Text(rsvp.rsvpStatus == 'going' ? 'ΠΑΩ' : 'ΜΕ ΕΝΔΙΑΦΕΡΕΙ',
                            style: AppTextStyles.mono(size: 9, color: AppColors.textAlpha(0.45))),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(rsvp.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(formatPartyStart(rsvp.startsAt),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.55))),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Text(crowd, style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.5))),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Δεν μπορέσαμε να φορτώσουμε τα events σου.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.6))),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _reloadRsvps,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                decoration: BoxDecoration(gradient: AppColors.purpleGradient, borderRadius: BorderRadius.circular(12)),
                child: const Text('Δοκίμασε ξανά', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1.5),
              ),
              child: const Icon(Icons.explore_outlined, color: AppColors.purple, size: 26),
            ),
            const SizedBox(height: 14),
            const Text('Δεν πας κάπου ακόμα', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('Ο χάρτης δείχνει τι γίνεται τώρα κοντά σου. Κάτι θα βρεις μέσα σε δύο τετράγωνα.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.textAlpha(0.55))),
            const SizedBox(height: 18),
            GestureDetector(
              onTap: () => widget.onNavigate?.call(MpTab.map),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                decoration: BoxDecoration(gradient: AppColors.purpleGradient, borderRadius: BorderRadius.circular(13)),
                child: const Text('Άνοιξε τον χάρτη', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: active ? Colors.white.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(label, style: AppTextStyles.mono(size: 10.5, color: active ? AppColors.text : AppColors.textAlpha(0.45))),
      ),
    );
  }
}
