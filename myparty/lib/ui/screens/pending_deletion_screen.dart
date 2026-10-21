import 'package:flutter/material.dart';

import '../../data/account_repository.dart';
import '../../services/auth_service.dart';
import '../../utils/english_date.dart';
import '../theme/app_theme.dart';

/// What a user with a pending deletion sees when they sign in, instead of the
/// app.
///
/// Before Phase 43 the deletion screen promised "you can restore it by signing
/// in again" and signing in restored nothing: `AuthGate` never read
/// `deleted_at`, so the user landed in an app that had quietly dropped them
/// from search, with no sign of why and the only way back four screens deep.
/// Signing in now asks the one question that matters, and nothing else runs
/// until it is answered. No device registration, no time zone write: an
/// account on its way out processes nothing it does not have to.
///
/// "Keep deleting" is a sign-out and nothing more. The deletion is already
/// scheduled, and `request_account_deletion` is idempotent anyway, so there is
/// nothing to re-request.
///
/// Every string is asserted in `test/pending_deletion_test.dart`.
class PendingDeletionScreen extends StatefulWidget {
  const PendingDeletionScreen({
    super.key,
    required this.deletionRequestedAt,
    required this.onRestored,
    this.repository,
    this.auth,
  });

  /// `profiles.deleted_at`.
  final DateTime deletionRequestedAt;

  /// Called once `cancel_account_deletion` has succeeded. The gate re-reads
  /// the profile row rather than trusting this, so a restore the server did
  /// not apply cannot let the user through.
  final VoidCallback onRestored;

  final AccountRepository? repository;
  final AuthService? auth;

  @override
  State<PendingDeletionScreen> createState() => _PendingDeletionScreenState();
}

class _PendingDeletionScreenState extends State<PendingDeletionScreen> {
  late final AccountRepository _accounts = widget.repository ?? AccountRepository();
  late final AuthService _auth = widget.auth ?? AuthService();

  bool _busy = false;

  /// Shown on the screen rather than in a snackbar: the user has nowhere else
  /// to go from here, so the message has to stay until they act on it.
  String? _error;

  Future<void> _restore() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _accounts.cancelDeletion();
      widget.onRestored();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Your account could not be restored. Check your connection and try again.';
      });
    }
  }

  Future<void> _signOut() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _auth.signOut();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not sign out. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = formatCalendarDateEn(AccountRepository.erasureDueAt(widget.deletionRequestedAt));

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
          children: [
            const Icon(Icons.schedule, size: 40, color: AppColors.destructive),
            const SizedBox(height: 18),
            Text(
              'Your account is scheduled for deletion on $date. Restore it?',
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, height: 1.3),
            ),
            const SizedBox(height: 14),
            // What restoring does and does not undo. Both halves are what
            // cancel_account_deletion actually does: it clears deleted_at and
            // nothing else.
            Text(
              'Restoring keeps your account, your profile and everything you have posted.',
              style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.textAlpha(0.7)),
            ),
            const SizedBox(height: 8),
            Text(
              'It does not undo what happened when you asked to delete it: parties you '
              'were hosting that had not started stay cancelled, and notifications and '
              'location stay off until you turn them on again in Settings.',
              style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.textAlpha(0.7)),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(fontSize: 12.5, color: AppColors.destructive)),
            ],
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _busy ? null : _restore,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.purpleDeep,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.all(14),
              ),
              child: const Text('Restore account', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _busy ? null : _signOut,
              style: TextButton.styleFrom(padding: const EdgeInsets.all(14)),
              child: Text(
                'Keep deleting and sign out',
                style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textAlpha(0.6)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
