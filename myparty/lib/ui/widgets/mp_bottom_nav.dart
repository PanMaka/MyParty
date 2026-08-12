import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum MpTab { feed, events, map, messages, profile }

/// The custom 5-tab bottom bar with a raised gradient circular map button,
/// matching the design's Ροή / Parties / Χάρτης / Μηνύματα / Προφίλ bar.
class MpBottomNav extends StatelessWidget {
  final MpTab current;
  final ValueChanged<MpTab> onSelect;

  const MpBottomNav({super.key, required this.current, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [AppColors.bg, AppColors.bg.withValues(alpha: 0.0)],
          stops: const [0.55, 1],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _item(MpTab.feed, Icons.waves_rounded, 'Ροή'),
          _item(MpTab.events, Icons.event_note_outlined, 'Parties'),
          _mapItem(),
          _item(MpTab.messages, Icons.chat_bubble_outline, 'Μηνύματα', dot: true),
          _item(MpTab.profile, Icons.person_outline, 'Προφίλ'),
        ],
      ),
    );
  }

  Widget _item(MpTab tab, IconData icon, String label, {bool dot = false}) {
    final active = current == tab;
    final color = active ? AppColors.text : AppColors.textAlpha(0.42);
    return Expanded(
      child: InkWell(
        onTap: () => onSelect(tab),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, size: 19, color: color),
                  if (dot)
                    Positioned(
                      top: -3,
                      right: -4,
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(color: AppColors.pink, shape: BoxShape.circle),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              Text(label,
                  style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mapItem() {
    return Expanded(
      child: InkWell(
        onTap: () => onSelect(MpTab.map),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.translate(
              offset: const Offset(0, -16),
              child: Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  gradient: AppColors.brandGradient,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.bg, width: 2.5),
                  boxShadow: [
                    BoxShadow(color: AppColors.purpleDeep.withValues(alpha: 0.55), blurRadius: 24, offset: const Offset(0, 8)),
                  ],
                ),
                child: const Icon(Icons.map_outlined, color: Colors.white, size: 20),
              ),
            ),
            const SizedBox(height: 5),
            const Text('Χάρτης',
                style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: AppColors.text)),
          ],
        ),
      ),
    );
  }
}
