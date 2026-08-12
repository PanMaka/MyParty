import 'package:flutter/material.dart';

import '../../models/mp_party.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import 'chat_screen.dart';

class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Text('Μηνύματα', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    Icon(Icons.search, size: 16, color: AppColors.textAlpha(0.4)),
                    const SizedBox(width: 8),
                    Text('Αναζήτηση', style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.45))),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.pink, shape: BoxShape.circle)),
                  const SizedBox(width: 7),
                  Text('ΑΠΟΨΕ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.6))),
                ],
              ),
            ),
            _chatRow(
              context,
              partyId: 'taratsa',
              title: 'Ταράτσα στο Κουκάκι',
              preview: 'Ζωή: παίρνω ταξί από Σύνταγμα, χωράει 2',
              time: '22:41',
              unread: 7,
              tint: AppColors.pink,
            ),
            _chatRow(
              context,
              partyId: 'vinyl',
              title: 'Techno Δευτέρα',
              preview: 'Vinyl Room: guest list μέχρι 00:30 στο όνομά σου',
              time: '21:05',
              tint: AppColors.purple,
              venueBadge: true,
            ),
            Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), color: AppColors.hairline),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _SectionLabel('ΟΛΑ ΤΑ ΑΛΛΑ'),
            ),
            _staticDmRow(
              title: 'Μετακόμιση Νεφέλης',
              preview: 'Νεφέλη: ποιος φέρνει ηχείο;',
              time: 'Τρι',
              colors: const [Color(0xFF1C1622), Color(0xFF151020)],
              privateIcon: true,
            ),
            _staticDmRow(
              title: 'Δημήτρης',
              preview: 'Έστειλα λινκ, δες αν παίζει',
              time: '20:12',
              colors: const [Color(0xFF2E1F28), Color(0xFF241820)],
              circle: true,
            ),
            _staticDmRow(
              title: 'Ελένη',
              preview: 'είσαι μέσα για ταράτσα;',
              time: 'Χθες',
              colors: const [Color(0xFF232C40), Color(0xFF1A2030)],
              circle: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _chatRow(
    BuildContext context, {
    required String partyId,
    required String title,
    required String preview,
    required String time,
    required Color tint,
    int? unread,
    bool venueBadge = false,
  }) {
    final party = mpParties[partyId]!;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(partyId: partyId))),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [tint.withValues(alpha: 0.1), Colors.transparent]),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 50,
              height: 50,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), border: Border.all(color: tint, width: 1.5)),
                    child: const DiagonalStripePlaceholder(colors: [Color(0xFF1C1622), Color(0xFF151020)]),
                  ),
                  Positioned(
                    bottom: -3,
                    right: -3,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(5)),
                      child: Text('${party.pop}', style: AppTextStyles.mono(size: 7.5)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700))),
                      const SizedBox(width: 6),
                      if (venueBadge)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(5)),
                          child: Text('VENUE', style: AppTextStyles.mono(size: 7.5, color: AppColors.purpleLight)),
                        )
                      else
                        Icon(Icons.lock, size: 11, color: tint),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: AppColors.textAlpha(0.6))),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(time, style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.4))),
                if (unread != null) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
                    child: Text('$unread', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _staticDmRow({
    required String title,
    required String preview,
    required String time,
    required List<Color> colors,
    bool privateIcon = false,
    bool circle = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(circle ? 99 : 15)),
            child: DiagonalStripePlaceholder(colors: colors),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700))),
                    if (privateIcon) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.lock, size: 11, color: AppColors.textAlpha(0.7)),
                    ],
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: AppColors.textAlpha(0.5))),
                ),
              ],
            ),
          ),
          Text(time, style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.4))),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45)));
  }
}
