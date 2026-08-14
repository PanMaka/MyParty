import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/mp_party.dart';
import '../../state/mp_store.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
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

class _KapsimoCard extends StatefulWidget {
  const _KapsimoCard();

  @override
  State<_KapsimoCard> createState() => _KapsimoCardState();
}

class _KapsimoCardState extends State<_KapsimoCard> {
  /// Local, not wired to `follows`. This whole card is a hardcoded design
  /// mock — "Kápsimo" has no `profiles` row, so there is no id to follow.
  /// Phase 4 replaces the card with real `party_posts` rows, and the button
  /// becomes a [FollowButton] on the real author then. Keeping it fake and
  /// obviously local beats inventing a placeholder uuid that would 42501.
  bool _following = false;

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
                  onPressed: () => setState(() => _following = !_following),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                    backgroundColor: _following ? Colors.white.withValues(alpha: 0.08) : null,
                    side: _following ? BorderSide.none : const BorderSide(color: AppColors.purple),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                    foregroundColor: _following ? AppColors.textAlpha(0.6) : AppColors.purpleLight,
                  ),
                  child: Text(_following ? 'Ακολουθείς' : 'Ακολούθησε',
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
