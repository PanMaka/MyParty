import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/account_repository.dart';
import 'package:myparty/services/auth_service.dart';
import 'package:myparty/ui/screens/account_deletion_screen.dart';
import 'package:myparty/utils/english_date.dart';

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

class _FakeAuthService extends AuthService {
  int signOuts = 0;

  @override
  Future<void> signOut() async => signOuts++;
}

/// One shared file, as the system share sheet would have received it.
typedef _SharedFile = ({String fileName, String contents, String mimeType});

Widget _wrap(
  AccountRepository repo, {
  AuthService? auth,
  List<_SharedFile>? shared,
}) =>
    MaterialApp(
      home: AccountDeletionScreen(
        repository: repo,
        auth: auth ?? _FakeAuthService(),
        now: () => DateTime(2026, 10, 21, 14),
        shareFile: ({required fileName, required contents, required mimeType}) async {
          shared?.add((fileName: fileName, contents: contents, mimeType: mimeType));
        },
      ),
    );

void main() {
  group('AccountDeletionScreen', () {
    // The App Store requirement is not "a screen exists" — it is that an
    // account can actually be deleted from inside the app. This asserts the
    // call reaches the repository, which is the only part a reviewer's tap
    // would exercise.
    testWidgets('the delete button reaches request_account_deletion, after a confirmation', (tester) async {
      final repo = _FakeAccountRepository();
      final auth = _FakeAuthService();
      await tester.pumpWidget(_wrap(repo, auth: auth));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();

      // The dialog names the date and the way back, and both are true: the
      // erasure is due 30 days on, and signing in now offers Restore.
      final due = formatCalendarDateEn(AccountRepository.erasureDueAt(DateTime.now()));
      expect(find.textContaining('permanently deleted on $due'), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('sign in and choose Restore')), findsOneWidget);

      // Nothing has happened yet: the confirmation is a real gate, not a
      // formality. A destructive irreversible action behind a single tap is
      // the failure mode this assertion exists to prevent.
      expect(repo.deletionRequests, 0);
      expect(find.text('Delete account?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.deletionRequests, 0, reason: 'cancelling the dialog must not delete the account');

      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(repo.deletionRequests, 1);
      // "You will be signed out" is a promise in the dialog, so it is asserted.
      expect(auth.signOuts, 1);
      expect(find.textContaining('Deletion failed'), findsNothing);
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
        find.text('You are signed out, and your account is permanently deleted after 30 days.'),
        findsOneWidget,
        reason: 'the grace period is the whole reason deletion is recoverable',
      );
      expect(
        find.text('Until then, you can sign in and choose Restore to keep it.'),
        findsOneWidget,
        reason:
            'signing in alone restores nothing; the gate asks, and cancel_account_deletion runs only '
            'when the user says Restore. The old copy said signing in was enough.',
      );
      expect(
        find.text(
          'Messages and comments you have written stay where they are, under an anonymous name '
          'instead of your username.',
        ),
        findsOneWidget,
        reason:
            'THE surprising one. Erasure keeps messages, DMs and comments under the tombstone handle, '
            'and a user who expected them to vanish must be told before they act.',
      );
      expect(
        find.text('Your location and notifications are deleted and turned off immediately, not in 30 days.'),
        findsOneWidget,
        reason: 'request_account_deletion purges user_devices and sets both consents false at T+0',
      );
      expect(
        find.text('Parties you are hosting that have not started yet are cancelled.'),
        findsOneWidget,
        reason: 'guests of a cancelled party are affected by this button too',
      );
      expect(
        find.text('Restoring does not bring cancelled parties back or turn notifications on again.'),
        findsOneWidget,
        reason: 'cancel_account_deletion clears deleted_at and nothing else',
      );
      // The old promises are gone.
      expect(find.textContaining('restore it by signing in again'), findsNothing);
      expect(find.textContaining('Deleted user'), findsNothing);
    });

    testWidgets('inside the grace period the screen offers recovery instead of deletion', (tester) async {
      final repo = _FakeAccountRepository(
        scheduledAt: DateTime.now().subtract(const Duration(days: 3)),
      );
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      expect(find.text('Your account is being deleted'), findsOneWidget);
      expect(
        find.text('Delete account'),
        findsNothing,
        reason: 'offering delete again to someone already deleting is a second clock they cannot see',
      );

      // 30 days of grace minus 3 elapsed. Asserting the arithmetic because an
      // off-by-one here is a number the user will plan around.
      expect(find.textContaining('26 days left'), findsOneWidget);
      expect(
        find.textContaining(formatCalendarDateEn(AccountRepository.erasureDueAt(repo.scheduledAt!))),
        findsOneWidget,
      );

      await tester.tap(find.text('Restore account'));
      await tester.pumpAndSettle();
      expect(repo.cancellations, 1);
    });

    testWidgets('the export is reachable without going near the delete button', (tester) async {
      final repo = _FakeAccountRepository();
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Export data'));
      await tester.pumpAndSettle();

      expect(repo.exports, 1);
      expect(repo.deletionRequests, 0, reason: 'exporting is not a step inside deleting');
    });

    testWidgets('the export is handed over as a dated JSON file, not the clipboard', (tester) async {
      final shared = <_SharedFile>[];
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(_wrap(_FakeAccountRepository(), shared: shared));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export data'));
      await tester.pumpAndSettle();

      expect(shared, hasLength(1));
      expect(shared.single.fileName, 'myparty-data-2026-10-21.json');
      expect(shared.single.mimeType, 'application/json');
      expect(shared.single.contents, '{"user_id":"me"}');
      expect(clipboard, isNull, reason: 'the whole account must not sit on the clipboard any more');
    });

    testWidgets('a failed deletion leaves the account alone and says so', (tester) async {
      final repo = _FakeAccountRepository(failDeletion: true);
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Deletion failed'), findsOneWidget);
      // Still on the active screen: a failure that looked like a success would
      // leave the user believing their account is gone when it is not.
      expect(find.text('Delete account'), findsOneWidget);
    });
  });
}
