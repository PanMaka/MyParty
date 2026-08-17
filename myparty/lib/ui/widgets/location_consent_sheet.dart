import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The explanation shown **before** the OS location prompt.
///
/// This sheet is a compliance requirement, not a UX nicety. The system dialog
/// says only "Allow MyParty to access your location?" — it cannot say that what
/// is stored is a ~100m cell rather than a precise fix, that it is erased after
/// 24 hours, that no other user ever sees it, or that switching it off deletes
/// what is already held. Consent given without knowing those things is not
/// informed consent, and the OS gives us exactly one chance to ask.
///
/// So the order is fixed and enforced by the fact that `LocationReporter`
/// requires `explanationAccepted`: sheet first, system prompt only on accept. It
/// also spends the OS prompt well — a user who was going to refuse refuses here,
/// where the answer is reversible, rather than at the system dialog, where on
/// Android a second refusal is permanent.
///
/// Returns true only if the user actively accepted. Dismissing by tapping
/// outside or swiping down returns null, which the caller must treat as a no —
/// silence is not consent.
Future<bool> showLocationConsentSheet(BuildContext context) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _LocationConsentSheet(),
  );
  return accepted ?? false;
}

class _LocationConsentSheet extends StatelessWidget {
  const _LocationConsentSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.sheet,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 10,
        bottom: MediaQuery.of(context).viewPadding.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const Text(
              'Πάρτι κοντά σου',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4),
            ),
            const SizedBox(height: 6),
            Text(
              'Για να σου στέλνουμε ειδοποίηση όταν ανοίγει ένα πάρτι δίπλα σου, '
              'χρειαζόμαστε την κατά προσέγγιση τοποθεσία σου. Να τι ακριβώς σημαίνει αυτό.',
              style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.textAlpha(0.62)),
            ),
            const SizedBox(height: 18),

            // Each line answers a question the OS dialog cannot, and each one is
            // a promise something in the schema actually keeps — the rounding
            // trigger, the 24h cron, owner-only RLS, the withdrawal trigger.
            // If any of those changes, this copy is wrong and has to change too.
            const _ConsentPoint(
              icon: Icons.grid_on,
              title: 'Περιοχή, όχι ακριβές σημείο',
              body: 'Αποθηκεύουμε ένα τετράγωνο ~100 μέτρων, όχι τη διεύθυνσή σου. '
                  'Το ακριβές στίγμα δεν φεύγει ποτέ από το κινητό σου.',
            ),
            const _ConsentPoint(
              icon: Icons.schedule,
              title: 'Σβήνεται μετά από 24 ώρες',
              body: 'Κρατάμε μόνο την τελευταία τοποθεσία. Δεν υπάρχει ιστορικό '
                  'των διαδρομών σου — πουθενά.',
            ),
            const _ConsentPoint(
              icon: Icons.visibility_off_outlined,
              title: 'Δεν τη βλέπει κανένας',
              body: 'Ούτε οι διοργανωτές, ούτε άλλοι χρήστες. Χρησιμοποιείται μόνο '
                  'από το σύστημα ειδοποιήσεων, που στέλνει πάρτι — ποτέ τοποθεσίες.',
            ),
            const _ConsentPoint(
              icon: Icons.toggle_off_outlined,
              title: 'Το κλείνεις όποτε θες',
              body: 'Μόλις το απενεργοποιήσεις, ό,τι έχει αποθηκευτεί διαγράφεται '
                  'αμέσως. Οι υπόλοιπες ειδοποιήσεις συνεχίζουν κανονικά.',
            ),

            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                'Στη συνέχεια θα εμφανιστεί το παράθυρο του λειτουργικού. '
                'Μπορείς να αρνηθείς και εκεί.',
                style: TextStyle(fontSize: 11.5, height: 1.45, color: AppColors.textAlpha(0.4)),
              ),
            ),
            const SizedBox(height: 16),

            GestureDetector(
              onTap: () => Navigator.of(context).pop(true),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: AppColors.purpleGradient,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text(
                  'Συμφωνώ, ενεργοποίησέ το',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Given the same visual weight as a real choice rather than being
            // buried as a text link. A decline that is hard to find is a consent
            // flow that produces agreements nobody meant.
            GestureDetector(
              onTap: () => Navigator.of(context).pop(false),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  border: Border.all(color: AppColors.hairline),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  'Όχι τώρα',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textAlpha(0.7),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConsentPoint extends StatelessWidget {
  const _ConsentPoint({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.purple.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 17, color: AppColors.purpleLight),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.textAlpha(0.52)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
