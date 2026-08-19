import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/account_repository.dart';
import '../../services/auth_service.dart';
import '../theme/app_theme.dart';

/// The in-app account deletion entry point.
///
/// App Store Review Guideline 5.1.1(v) requires this wherever an account can
/// be created, and requires it to actually initiate deletion rather than point
/// at a support address — which is why the button here calls
/// `request_account_deletion` directly and the screen is reachable in two taps
/// from the profile tab.
///
/// The screen exists as a screen, not a dialog, for one reason: everything on
/// it is a consequence the user is entitled to read before they act, and an
/// AlertDialog is the wrong container for six lines of consequence. The same
/// argument `showLocationConsentSheet` makes for consent — the OS dialog
/// cannot say what is stored, so a sheet says it first — applies in reverse
/// here. This is the only place the app can explain what "delete" means, and
/// what it means is unusual enough to need explaining: the messages stay.
///
/// Every string below is asserted in `test/account_test.dart`. They are the
/// interface, not decoration — a deletion screen that promises something the
/// server does not do is worse than no screen.
class AccountDeletionScreen extends StatefulWidget {
  const AccountDeletionScreen({super.key, this.repository});

  /// Injectable so widget tests can subclass [AccountRepository] without a
  /// Supabase client ever existing, exactly as [ProfileScreen] does.
  final AccountRepository? repository;

  @override
  State<AccountDeletionScreen> createState() => _AccountDeletionScreenState();
}

class _AccountDeletionScreenState extends State<AccountDeletionScreen> {
  late final AccountRepository _accounts = widget.repository ?? AccountRepository();

  bool _busy = false;
  DateTime? _scheduledAt;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final scheduled = await _accounts.deletionScheduledAt();
    if (!mounted) return;
    setState(() {
      _scheduledAt = scheduled;
      _loaded = true;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  /// The export is offered ABOVE the delete button and never as a step inside
  /// it. Bundling them would make the export feel like part of the deletion
  /// flow, and it is the opposite — the one action here that a user should be
  /// able to take without consequence, as often as they like.
  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final json = await _accounts.exportData();
      await Clipboard.setData(ClipboardData(text: json));
      _toast('Τα δεδομένα σου αντιγράφηκαν (${json.length} χαρακτήρες)');
    } catch (error) {
      _toast('Η εξαγωγή απέτυχε: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.sheet,
        title: const Text('Διαγραφή λογαριασμού;'),
        content: const Text(
          'Ο λογαριασμός σου θα διαγραφεί οριστικά σε 30 ημέρες. '
          'Μέχρι τότε μπορείς να τον επαναφέρεις κάνοντας ξανά σύνδεση.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Άκυρο'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Διαγραφή', style: TextStyle(color: Color(0xFFE5484D))),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (_busy) return;
    setState(() => _busy = true);

    try {
      await _accounts.requestDeletion();
      // Signed out immediately: the account is now in its grace period and
      // every discovery surface has dropped the user, so leaving them inside a
      // session would show them an app that has quietly stopped working. The
      // way back in is a sign-in, which is also the way the account is
      // recovered — one action, not two.
      await AuthService().signOut();
    } catch (error) {
      _toast('Η διαγραφή απέτυχε: $error');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelDeletion() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _accounts.cancelDeletion();
      await _load();
      _toast('Ο λογαριασμός σου δεν θα διαγραφεί');
    } catch (error) {
      _toast('Κάτι πήγε στραβά: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.canvas,
        elevation: 0,
        title: const Text('Ο λογαριασμός μου', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: _scheduledAt != null ? _pendingSections() : _activeSections(),
            ),
    );
  }

  // ----------------------------------------------------------------
  // The normal state.
  // ----------------------------------------------------------------
  List<Widget> _activeSections() {
    return [
      Text('ΤΑ ΔΕΔΟΜΕΝΑ ΜΟΥ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
      const SizedBox(height: 9),
      _card(
        child: InkWell(
          onTap: _busy ? null : _export,
          child: const Padding(
            padding: EdgeInsets.all(13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Εξαγωγή δεδομένων', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                SizedBox(height: 2),
                Text(
                  'Το προφίλ, τα πάρτι, οι συμμετοχές, οι δημοσιεύσεις και τα μηνύματά σου, σε JSON.',
                  style: TextStyle(fontSize: 11, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),

      const SizedBox(height: 22),
      Text('ΔΙΑΓΡΑΦΗ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
      const SizedBox(height: 9),

      // The five facts. Each one is a thing the server actually does, and each
      // one is asserted in the widget test — including the third, which is the
      // surprising one and the reason this list exists at all.
      _card(
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _Fact('Ο λογαριασμός σου διαγράφεται οριστικά μετά από 30 ημέρες.'),
              _Fact('Μέχρι τότε μπορείς να τον επαναφέρεις κάνοντας ξανά σύνδεση.'),
              _Fact('Τα μηνύματα που έχεις στείλει παραμένουν στις συνομιλίες, ως «Διαγραμμένος χρήστης».'),
              _Fact('Η τοποθεσία σου και οι ειδοποιήσεις διαγράφονται αμέσως, όχι σε 30 ημέρες.'),
              _Fact('Τα πάρτι που δεν έχουν ξεκινήσει ακυρώνονται.', last: true),
            ],
          ),
        ),
      ),

      const SizedBox(height: 14),
      _dangerButton(
        label: 'Διαγραφή λογαριασμού',
        onTap: _busy ? null : _confirmAndDelete,
      ),
    ];
  }

  // ----------------------------------------------------------------
  // The grace period.
  // ----------------------------------------------------------------
  List<Widget> _pendingSections() {
    final erasesAt = _scheduledAt!.add(const Duration(days: 30));
    final daysLeft = erasesAt.difference(DateTime.now()).inDays;

    return [
      _card(
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ο λογαριασμός σου διαγράφεται',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                daysLeft > 0
                    ? 'Απομένουν $daysLeft ημέρες. Μέχρι τότε μπορείς να τον επαναφέρεις.'
                    : 'Η διαγραφή θα ολοκληρωθεί σύντομα.',
                style: TextStyle(fontSize: 12, height: 1.5, color: AppColors.textAlpha(0.6)),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 14),
      _card(
        child: InkWell(
          onTap: _busy ? null : _cancelDeletion,
          child: const Padding(
            padding: EdgeInsets.all(13),
            child: Center(
              child: Text('Επαναφορά λογαριασμού', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _card({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        color: Colors.white.withValues(alpha: 0.035),
        border: Border.all(color: AppColors.hairline),
      ),
      child: child,
    );
  }

  Widget _dangerButton({required String label, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          color: const Color(0xFFE5484D).withValues(alpha: 0.10),
          border: Border.all(color: const Color(0xFFE5484D).withValues(alpha: 0.35)),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFE5484D)),
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.text, {this.last = false});

  final String text;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: 8),
            child: Container(
              width: 3,
              height: 3,
              decoration: BoxDecoration(color: AppColors.textAlpha(0.4), shape: BoxShape.circle),
            ),
          ),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 11.5, height: 1.5)),
          ),
        ],
      ),
    );
  }
}
