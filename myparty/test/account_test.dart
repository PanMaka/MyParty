import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/account_repository.dart';
import 'package:myparty/ui/screens/account_deletion_screen.dart';

/// Stands in for the real repository. Subclasses rather than implements so it
/// stays in sync with the real constructor, and overrides every method that
/// touches the network — `AccountRepository` resolves its client lazily, so no
/// Supabase client is ever constructed here. Same shape as
/// `_FakeProfileRepository` in profile_test.dart.
class _FakeAccountRepository extends AccountRepository {
  _FakeAccountRepository({this.scheduledAt, this.failDeletion = false});

  DateTime? scheduledAt;
  final bool failDeletion;

  int deletionRequests = 0;
  int cancellations = 0;
  int exports = 0;

  @override
  Future<DateTime?> deletionScheduledAt() async => scheduledAt;

  @override
  Future<DateTime> requestDeletion() async {
    deletionRequests++;
    if (failDeletion) throw Exception('nope');
    scheduledAt = DateTime.now();
    return scheduledAt!;
  }

  @override
  Future<void> cancelDeletion() async {
    cancellations++;
    scheduledAt = null;
  }

  @override
  Future<String> exportData() async {
    exports++;
    return '{"user_id":"me"}';
  }
}

Widget _wrap(AccountRepository repo) =>
    MaterialApp(home: AccountDeletionScreen(repository: repo));

void main() {
  group('AccountDeletionScreen', () {
    // The App Store requirement is not "a screen exists" — it is that an
    // account can actually be deleted from inside the app. This asserts the
    // call reaches the repository, which is the only part a reviewer's tap
    // would exercise.
    testWidgets('the delete button reaches request_account_deletion, after a confirmation', (tester) async {
      final repo = _FakeAccountRepository();
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Διαγραφή λογαριασμού'));
      await tester.pumpAndSettle();

      // Nothing has happened yet: the confirmation is a real gate, not a
      // formality. A destructive irreversible action behind a single tap is
      // the failure mode this assertion exists to prevent.
      expect(repo.deletionRequests, 0);
      expect(find.text('Διαγραφή λογαριασμού;'), findsOneWidget);

      await tester.tap(find.text('Άκυρο'));
      await tester.pumpAndSettle();
      expect(repo.deletionRequests, 0, reason: 'cancelling the dialog must not delete the account');

      await tester.tap(find.text('Διαγραφή λογαριασμού'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Διαγραφή'));
      await tester.pumpAndSettle();

      expect(repo.deletionRequests, 1);
    });

    // These five strings are the interface. The server does five specific
    // things at T+0 and one at T+30d, and each line below corresponds to one
    // of them — a screen that promises something else would be worse than no
    // screen at all. Asserted individually so that deleting one is a test
    // failure rather than a silently shorter list.
    testWidgets('the screen states every consequence the server actually produces', (tester) async {
      await tester.pumpWidget(_wrap(_FakeAccountRepository()));
      await tester.pumpAndSettle();

      expect(
        find.text('Ο λογαριασμός σου διαγράφεται οριστικά μετά από 30 ημέρες.'),
        findsOneWidget,
        reason: 'the grace period is the whole reason deletion is recoverable',
      );
      expect(
        find.text('Μέχρι τότε μπορείς να τον επαναφέρεις κάνοντας ξανά σύνδεση.'),
        findsOneWidget,
        reason: 'cancel_account_deletion exists and the user has to know how to reach it',
      );
      expect(
        find.text('Τα μηνύματα που έχεις στείλει παραμένουν στις συνομιλίες, ως «Διαγραμμένος χρήστης».'),
        findsOneWidget,
        reason:
            'THE surprising one. The tombstone design means messages survive attributed to an '
            'anonymous handle, and a user who expected them to vanish must be told before they act.',
      );
      expect(
        find.text('Η τοποθεσία σου και οι ειδοποιήσεις διαγράφονται αμέσως, όχι σε 30 ημέρες.'),
        findsOneWidget,
        reason: 'request_account_deletion purges user_devices at T+0 — the screen should say so',
      );
      expect(
        find.text('Τα πάρτι που δεν έχουν ξεκινήσει ακυρώνονται.'),
        findsOneWidget,
        reason: 'guests of a cancelled party are affected by this button too',
      );
    });

    testWidgets('inside the grace period the screen offers recovery instead of deletion', (tester) async {
      final repo = _FakeAccountRepository(
        scheduledAt: DateTime.now().subtract(const Duration(days: 3)),
      );
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      expect(find.text('Ο λογαριασμός σου διαγράφεται'), findsOneWidget);
      expect(
        find.text('Διαγραφή λογαριασμού'),
        findsNothing,
        reason: 'offering delete again to someone already deleting is a second clock they cannot see',
      );

      // 30 days of grace minus 3 elapsed. Asserting the arithmetic because an
      // off-by-one here is a number the user will plan around.
      expect(find.textContaining('Απομένουν 26 ημέρες'), findsOneWidget);

      await tester.tap(find.text('Επαναφορά λογαριασμού'));
      await tester.pumpAndSettle();
      expect(repo.cancellations, 1);
    });

    testWidgets('the export is reachable without going near the delete button', (tester) async {
      final repo = _FakeAccountRepository();
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Εξαγωγή δεδομένων'));
      await tester.pumpAndSettle();

      expect(repo.exports, 1);
      expect(repo.deletionRequests, 0, reason: 'exporting is not a step inside deleting');
    });

    testWidgets('a failed deletion leaves the account alone and says so', (tester) async {
      final repo = _FakeAccountRepository(failDeletion: true);
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Διαγραφή λογαριασμού'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Διαγραφή'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Η διαγραφή απέτυχε'), findsOneWidget);
      // Still on the active screen: a failure that looked like a success would
      // leave the user believing their account is gone when it is not.
      expect(find.text('Διαγραφή λογαριασμού'), findsOneWidget);
    });
  });
}
