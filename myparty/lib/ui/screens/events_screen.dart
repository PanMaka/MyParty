import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/mp_party.dart';
import '../../state/mp_store.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/mp_bottom_nav.dart';
import '../widgets/party_card.dart';
import '../widgets/party_detail_sheet.dart';
import '../widgets/privacy_badge.dart';
import 'host_wizard_screen.dart';

class EventsScreen extends StatefulWidget {
  final ValueChanged<MpTab>? onNavigate;

  const EventsScreen({super.key, this.onNavigate});

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  bool _showAll = true;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MpStore>();
    final tonight = ['taratsa', 'vinyl', 'maria'].where(store.interestedIn).toList();
    final thisWeek = ['anodos'].where(store.interestedIn).toList();
    final later = ['nefeli'].where(store.interestedIn).toList();
    final empty = tonight.isEmpty && thisWeek.isEmpty && later.isEmpty;

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
                  : empty
                      ? _emptyState(context)
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(14, 16, 14, 96),
                          children: [
                            if (tonight.isNotEmpty) _section(context, 'ΑΠΟΨΕ', tonight, live: true),
                            if (thisWeek.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              _section(context, 'ΑΥΤΗ ΤΗ ΒΔΟΜΑΔΑ', thisWeek),
                            ],
                            if (later.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              _section(context, 'ΑΡΓΟΤΕΡΑ', later),
                            ],
                            const SizedBox(height: 20),
                            _pastSection(),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<String> ids, {bool live = false}) {
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
          children: [for (final id in ids) _row(context, id)],
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String id) {
    final party = mpParties[id]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: GestureDetector(
        onTap: () => showPartyDetailSheet(context, id),
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(15),
            border: Border(
              top: BorderSide(color: (party.isPrivate ? AppColors.pink : AppColors.purple).withValues(alpha: 0.3)),
              bottom: BorderSide(color: (party.isPrivate ? AppColors.pink : AppColors.purple).withValues(alpha: 0.3)),
              right: BorderSide(color: (party.isPrivate ? AppColors.pink : AppColors.purple).withValues(alpha: 0.3)),
              left: BorderSide(color: party.isPrivate ? AppColors.pink : AppColors.purple, width: 3),
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
                  colors: party.isPrivate ? const [Color(0xFF1C1622), Color(0xFF151020)] : const [Color(0xFF1D1730), Color(0xFF161126)],
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
                        PrivacyBadge(type: party.type),
                        const SizedBox(width: 5),
                        Text(party.isPrivate ? 'ΚΑΛΕΣΜΕΝΟΣ' : 'ΕΝΔΙΑΦΕΡΟΜΑΙ',
                            style: AppTextStyles.mono(size: 9, color: AppColors.textAlpha(0.45))),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(party.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('${party.time} · ${party.host}',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.55))),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Text(party.crowd, style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.5))),
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

  Widget _pastSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 9),
          child: Text('ΠΕΡΑΣΜΕΝΑ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.35))),
        ),
        Opacity(
          opacity: 0.6,
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.02),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(11)),
                  child: const DiagonalStripePlaceholder(colors: [Color(0xFF191521), Color(0xFF141020)]),
                ),
                const SizedBox(width: 11),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Kápsimo x Λευτέρης', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                      SizedBox(height: 2),
                      Text('Χθες · Γκάζι · 4 φωτό σου στο story',
                          style: TextStyle(fontSize: 11.5, color: Color(0x73F4F1F8))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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
