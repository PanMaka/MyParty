import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/mp_party.dart';
import '../../state/mp_store.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_stack.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/hype_bar.dart';
import '../widgets/party_detail_sheet.dart';
import '../widgets/privacy_badge.dart';
import '../widgets/story_picker_sheet.dart';
import 'story_viewer_screen.dart';

class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            _header(context),
            const SizedBox(height: 2),
            _storyRow(context),
            const SizedBox(height: 16),
            Container(height: 1, color: Colors.white.withValues(alpha: 0.07), margin: const EdgeInsets.only(bottom: 16)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                children: [
                  _VinylCard(),
                  const SizedBox(height: 14),
                  _TaratsaCard(),
                  const SizedBox(height: 14),
                  _KapsimoCard(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('MyParty', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
          Row(
            children: [
              OutlinedButton(
                onPressed: () => showStoryPickerSheet(context),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                  foregroundColor: AppColors.text,
                ),
                child: const Text('+ Story', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 9),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withValues(alpha: 0.14))),
                child: Stack(
                  children: [
                    const Center(child: Icon(Icons.notifications_none, size: 16, color: AppColors.text)),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: AppColors.pink, shape: BoxShape.circle)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _storyRow(BuildContext context) {
    return SizedBox(
      height: 146,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          GestureDetector(
            onTap: () => showStoryPickerSheet(context),
            child: Container(
              width: 104,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.2), style: BorderStyle.solid),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(gradient: LinearGradient(colors: [AppColors.purpleDeep, AppColors.pink]), shape: BoxShape.circle),
                    child: const Icon(Icons.add, color: Colors.white, size: 19),
                  ),
                  const SizedBox(height: 9),
                  Text('Ανέβασε\nστο πάρτι σου',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, height: 1.3, color: AppColors.textAlpha(0.6))),
                ],
              ),
            ),
          ),
          _storyTile(context, 'taratsa', 'Ταράτσα στο Κουκάκι', 'Κουκάκι · 24 μέσα'),
          _storyTile(context, 'vinyl', 'Techno Δευτέρα', 'Vinyl Room · 180 μέσα', venue: true),
          _storyTile(context, 'maria', 'Γενέθλια Μαρίας', 'Εξάρχεια · 31 μέσα'),
          _kapsimoStoryTile(context),
        ],
      ),
    );
  }

  Widget _storyTile(BuildContext context, String id, String title, String sub, {bool venue = false}) {
    final party = mpParties[id]!;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => StoryViewerScreen(partyId: id)),
      ),
      child: Container(
        width: 104,
        margin: const EdgeInsets.only(right: 10),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: party.isPrivate ? AppColors.pink : AppColors.purple, width: 2),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DiagonalStripePlaceholder(colors: party.isPrivate ? const [Color(0xFF1C1622), Color(0xFF151020)] : const [Color(0xFF191428), Color(0xFF130F20)]),
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
              top: 7,
              left: 7,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(99)),
                child: Text('ΤΩΡΑ', style: AppTextStyles.mono(size: 8.5)),
              ),
            ),
            Positioned(
              top: 7,
              right: 7,
              child: venue
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(5)),
                      child: Text('VENUE', style: AppTextStyles.mono(size: 7.5)),
                    )
                  : Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(color: AppColors.pink.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(5)),
                      child: const Icon(Icons.lock, size: 9, color: Colors.white),
                    ),
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, height: 1.2)),
                  Text(sub, style: TextStyle(fontSize: 9.5, color: AppColors.textAlpha(0.6))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kapsimoStoryTile(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const StoryViewerScreen(partyId: 'kapsimo')),
      ),
      child: Container(
        width: 104,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.hairline)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DiagonalStripePlaceholder(colors: [Color(0xFF191428), Color(0xFF130F20)], label: 'poster\nKápsimo'),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [AppColors.bg.withValues(alpha: 0.9), Colors.transparent],
                  stops: const [0.42, 1],
                ),
              ),
            ),
            Positioned(
              top: 7,
              right: 7,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(5)),
                child: Text('VENUE', style: AppTextStyles.mono(size: 7.5)),
              ),
            ),
            const Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Kápsimo', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                  Text('Γκάζι · από 00:00', style: TextStyle(fontSize: 9.5, color: Color(0x99F4F1F8))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VinylCard extends StatelessWidget {
  const _VinylCard();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MpStore>();
    final party = mpParties['vinyl']!;
    final interested = store.interestedIn('vinyl');

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.purple.withValues(alpha: 0.35)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.purpleDeep.withValues(alpha: 0.16), Colors.white.withValues(alpha: 0.03)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(11)),
                  child: const DiagonalStripePlaceholder(colors: [Color(0xFF241E3C), Color(0xFF1B1630)], label: 'LOGO'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Text('Vinyl Room', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                        const SizedBox(width: 6),
                        const PrivacyBadge(type: MpPartyType.public),
                      ]),
                      Text('Ψυρρή · χορηγούμενο', style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.5))),
                    ],
                  ),
                ),
                Icon(Icons.more_horiz, color: AppColors.textAlpha(0.4)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => showPartyDetailSheet(context, 'vinyl'),
            child: SizedBox(
              height: 172,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DiagonalStripePlaceholder(colors: const [Color(0xFF1D1730), Color(0xFF161126)], label: party.imgLabel),
                  Positioned(
                    top: 11,
                    left: 11,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(99)),
                      child: Text('ΣΕ 1:14 ΩΡΕΣ', style: AppTextStyles.mono(size: 11, weight: FontWeight.w700)),
                    ),
                  ),
                  Positioned(
                    left: 11,
                    right: 11,
                    bottom: 11,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Techno Δευτέρα · DJ Ίρις',
                            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.4, height: 1.15)),
                        Text('Απόψε 23:00 · Σαρρή 12, Ψυρρή', style: TextStyle(fontSize: 12, color: AppColors.textAlpha(0.65))),
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
                HypeBar(
                  percent: store.hypeOf('vinyl'),
                  label: '${store.hypeOf('vinyl')}% · ανεβαίνει',
                  onTap: () => store.bump('vinyl', 7),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text('Ανεβαίνει με likes και ενδιαφέρον. Πέφτει όταν ησυχάσει.',
                      style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.4))),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      _reactionPill(
                        onTap: () => store.like('vinyl', hypeBump: 3),
                        icon: null,
                        gradientDot: true,
                        label: '${store.likesOf('vinyl')}',
                      ),
                      const SizedBox(width: 8),
                      _reactionPill(
                        onTap: () => showPartyDetailSheet(context, 'vinyl'),
                        icon: Icons.chat_bubble_outline,
                        label: '34',
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _interestButton(
                          interested: interested,
                          onLabel: 'Μ’ ενδιαφέρει',
                          offLabel: 'Στα events μου ✓',
                          gradient: AppColors.purpleGradient,
                          onTap: () => store.toggleInterest('vinyl', hypeBumpOnJoin: 6),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 11),
                  child: AvatarStack(
                    caption: '${store.interestedCountFor('vinyl')} ενδιαφέρονται · η Ελένη, ο Άρης και 4 φίλοι σου',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TaratsaCard extends StatelessWidget {
  const _TaratsaCard();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MpStore>();
    final party = mpParties['taratsa']!;
    final interested = store.interestedIn('taratsa');

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.pink.withValues(alpha: 0.35)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.pink.withValues(alpha: 0.12), Colors.white.withValues(alpha: 0.03)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  clipBehavior: Clip.antiAlias,
                  decoration: const BoxDecoration(shape: BoxShape.circle),
                  child: const DiagonalStripePlaceholder(colors: [Color(0xFF2E1F28), Color(0xFF241820)]),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: const [
                        Text('Δημήτρης', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                        SizedBox(width: 6),
                        PrivacyBadge(type: MpPartyType.private),
                      ]),
                      Text('σε κάλεσε · 18 καλεσμένοι', style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.5))),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 0, 13, 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => showPartyDetailSheet(context, 'taratsa'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(party.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(party.desc, style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.textAlpha(0.6))),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 11),
                  child: Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(9)),
                        child: Text('23:30', style: AppTextStyles.mono(size: 11, weight: FontWeight.w600)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(9)),
                        child: const Text('Δημητρακοπούλου 41', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(9)),
                        child: const Text('400 μ. από σένα', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500)),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: HypeBar(
                    percent: store.hypeOf('taratsa'),
                    label: '${store.hypeOf('taratsa')}% · ζεσταίνεται',
                    gradient: const LinearGradient(colors: [AppColors.purpleDeep, AppColors.pink]),
                    onTap: () => store.bump('taratsa', 9),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      _reactionPill(onTap: () => store.like('taratsa', hypeBump: 4), gradientDot: true, label: '${store.likesOf('taratsa')}'),
                      const SizedBox(width: 8),
                      _reactionPill(onTap: () => showPartyDetailSheet(context, 'taratsa'), icon: Icons.chat_bubble_outline, label: '61'),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _interestButton(
                          interested: interested,
                          onLabel: 'Έρχομαι',
                          offLabel: 'Έρχεσαι ✓',
                          gradient: AppColors.pinkGradient,
                          onTap: () => store.toggleInterest('taratsa', hypeBumpOnJoin: 8),
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
  }
}

class _KapsimoCard extends StatelessWidget {
  const _KapsimoCard();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MpStore>();

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
        color: Colors.white.withValues(alpha: 0.03),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(11)),
                  child: const DiagonalStripePlaceholder(colors: [Color(0xFF241E3C), Color(0xFF1B1630)], label: 'LOGO'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: const [
                        Text('Kápsimo', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                        SizedBox(width: 6),
                        PrivacyBadge(type: MpPartyType.public),
                      ]),
                      Text('Χθες το βράδυ · Γκάζι', style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.5))),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: store.toggleFollow,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                    backgroundColor: store.following ? Colors.white.withValues(alpha: 0.08) : null,
                    side: store.following ? BorderSide.none : const BorderSide(color: AppColors.purple),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                    foregroundColor: store.following ? AppColors.textAlpha(0.6) : AppColors.purpleLight,
                  ),
                  child: Text(store.following ? 'Ακολουθείς' : 'Ακολούθησε',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => showPartyDetailSheet(context, 'kapsimo'),
            child: SizedBox(
              height: 190,
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: DiagonalStripePlaceholder(colors: const [Color(0xFF1A1522), Color(0xFF141020)], label: 'φωτό πίστας'),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(child: DiagonalStripePlaceholder(colors: const [Color(0xFF1A1522), Color(0xFF141020)], label: 'clip')),
                        const SizedBox(height: 3),
                        Expanded(child: DiagonalStripePlaceholder(colors: const [Color(0xFF1A1522), Color(0xFF141020)], label: '+14')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 12, 13, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Γέμισε μέχρι τις 04:00. Ευχαριστούμε όσους ήρθαν — την Παρασκευή ξανά με τον Λευτέρη στα decks.',
                    style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.textAlpha(0.85))),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      _reactionPill(onTap: () => store.like('kapsimo'), gradientDot: true, label: '${store.likesOf('kapsimo')}'),
                      const SizedBox(width: 8),
                      _reactionPill(onTap: null, icon: Icons.chat_bubble_outline, label: '27'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _reactionPill({VoidCallback? onTap, IconData? icon, bool gradientDot = false, required String label}) {
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
          if (gradientDot)
            Container(width: 13, height: 13, decoration: const BoxDecoration(gradient: AppColors.likeGradient, shape: BoxShape.circle))
          else if (icon != null)
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
