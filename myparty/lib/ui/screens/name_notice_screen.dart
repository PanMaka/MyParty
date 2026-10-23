import 'package:flutter/material.dart';

import '../../data/profile_repository.dart';
import '../theme/app_theme.dart';

/// The one-time notice for a name stored before Phase 49.
///
/// Those users were told "Only you can see your name". The server keeps such a
/// name owner-only (`user_names.shown_at` is null) until the user answers here,
/// so nothing is published on their behalf: OK calls `acknowledge_name_shown`,
/// and Remove my name deletes it. An account that never opens the app again
/// never has its name shown. Both answers let the user through; neither is
/// pre-selected by leaving the screen, because there is no other way out of it.
///
/// Every string is asserted in `test/name_notice_test.dart`.
class NameNoticeScreen extends StatefulWidget {
  const NameNoticeScreen({
    super.key,
    required this.name,
    required this.onAnswered,
    this.repository,
  });

  /// "First Last", as stored.
  final String name;

  /// Called once the server has taken either answer.
  final VoidCallback onAnswered;

  final ProfileRepository? repository;

  static const headline = 'Your name is now shown on your profile.';
  static const changeHint = 'You can change it in Edit profile.';

  @override
  State<NameNoticeScreen> createState() => _NameNoticeScreenState();
}

class _NameNoticeScreenState extends State<NameNoticeScreen> {
  late final ProfileRepository _profiles = widget.repository ?? ProfileRepository();

  bool _busy = false;

  /// On the screen, not in a snackbar: the user cannot leave until it works.
  String? _error;

  Future<void> _answer(Future<void> Function() write, String failure) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await write();
      widget.onAnswered();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failure;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 13, height: 1.5, color: AppColors.textAlpha(0.7));

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
          children: [
            const Icon(Icons.badge_outlined, size: 40, color: AppColors.purpleLight),
            const SizedBox(height: 18),
            const Text(
              NameNoticeScreen.headline,
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, height: 1.3),
            ),
            const SizedBox(height: 14),
            Text(
              'People signed in to MyParty will see ${widget.name} under your username. '
              '${NameNoticeScreen.changeHint}',
              style: muted,
            ),
            const SizedBox(height: 8),
            // True as written: until one of the buttons below succeeds, the
            // server has not shown it to anyone.
            Text(
              'Until now only you could see your name, and nobody else sees it until you tap OK.',
              style: muted,
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(fontSize: 12.5, color: AppColors.destructive)),
            ],
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _answer(_profiles.acknowledgeNameShown,
                      'Something went wrong. Check your connection and try again.'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.purpleDeep,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.all(14),
              ),
              child: const Text('OK', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _answer(_profiles.clearNames,
                      'Your name was not removed. Check your connection and try again.'),
              style: TextButton.styleFrom(padding: const EdgeInsets.all(14)),
              child: Text(
                'Remove my name',
                style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textAlpha(0.6)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
