import 'package:flutter/material.dart';

import '../../models/mp_party.dart';
import '../../models/mp_story_item.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/privacy_badge.dart';

/// Full-screen story viewer: tap to advance through [mpStory] frames.
class StoryViewerScreen extends StatefulWidget {
  final String partyId;

  const StoryViewerScreen({super.key, required this.partyId});

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  int _index = 0;

  void _advance() {
    if (_index >= mpStory.length - 1) {
      Navigator.of(context).pop();
    } else {
      setState(() => _index++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final party = mpParties[widget.partyId]!;
    final frame = mpStory[_index];

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: GestureDetector(
        onTap: _advance,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DiagonalStripePlaceholder(colors: frame.colors, label: frame.label),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        for (var i = 0; i < mpStory.length; i++)
                          Expanded(
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              height: 2.5,
                              decoration: BoxDecoration(
                                color: i < _index
                                    ? Colors.white
                                    : (i == _index ? Colors.white.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.28)),
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: party.isPrivate ? AppColors.pink : AppColors.purple, width: 1.5),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: const DiagonalStripePlaceholder(
                            colors: [Color(0xFF241E3C), Color(0xFF1B1630)],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(party.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                                  ),
                                  const SizedBox(width: 6),
                                  PrivacyBadge(type: party.type),
                                ],
                              ),
                              Text('${party.posters} · ${_index + 1} από ${mpStory.length}',
                                  style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.55))),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), shape: BoxShape.circle),
                            child: const Icon(Icons.close, size: 15, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 12,
              bottom: 96,
              child: Container(
                padding: const EdgeInsets.fromLTRB(7, 6, 11, 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: const BoxDecoration(color: Color(0xFF2E1F28), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 7),
                    Text(frame.author, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 6),
                    Text(frame.time, style: AppTextStyles.mono(size: 9.5, color: AppColors.textAlpha(0.5))),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 40,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
                      ),
                      child: Text('Στείλε μήνυμα στο πάρτι…',
                          style: TextStyle(fontSize: 12.5, color: AppColors.textAlpha(0.5))),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 42,
                    height: 42,
                    decoration: const BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle),
                    child: const Icon(Icons.arrow_upward, size: 17, color: Colors.white),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
