import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/account_repository.dart';
import 'package:myparty/services/auth_service.dart';
import 'package:myparty/ui/screens/auth_gate.dart';
import 'package:myparty/ui/screens/pending_deletion_screen.dart';

/// Overrides every network method; `AccountRepository` resolves its client
/// lazily, so no Supabase client is ever constructed.
class _FakeAccountRepository extends AccountRepository {
  _FakeAccountRepository({this.failCancel = false});

  final bool failCancel;
  int cancellations = 0;

  @override
  Future<void> cancelDeletion() async {
    cancellations++;
    if (failCancel) throw Exception('offline');
  }
}

class _FakeAuthService extends AuthService {
  int signOuts = 0;

  @override
  Future<void> signOut() async => signOuts++;
}

final _requestedAt = DateTime(2026, 10, 21, 14, 30);
const _headline = 'Your account is scheduled for deletion on 20 Nov 2026. Restore it?';

void main() {
  group('PendingDeletionScreen', () {
    Future<({_FakeAccountRepository repo, _FakeAuthService auth, List<int> restored})> pump(
      WidgetTester tester, {
      bool failCancel = false,
    }) async {
      final repo = _FakeAccountRepository(failCancel: failCancel);
      final auth = _FakeAuthService();
      final restored = <int>[];
      await tester.pumpWidget(MaterialApp(
        home: PendingDeletionScreen(
          deletionRequestedAt: _requestedAt,
          onRestored: () => restored.add(1),
          repository: repo,
          auth: auth,
        ),
      ));
      await tester.pumpAndSettle();
      return (repo: repo, auth: auth, restored: restored);
    }

    testWidgets('names the date the account is due to be erased, and asks', (tester) async {
      await pump(tester);

      // Requested 21 Oct, erased 30 days later: 20 Nov. The date is the one
      // number on this screen the user will plan around.
      expect(find.text(_headline), findsOneWidget);
      expect(find.text('Restore account'), findsOneWidget);
      expect(find.text('Keep deleting and sign out'), findsOneWidget);
      // What restoring does not undo, stated before the choice.
      expect(find.textContaining('stay cancelled'), findsOneWidget);
      expect(find.textContaining('stay off until you turn them on again'), findsOneWidget);
    });

    testWidgets('Restore calls cancel_account_deletion, then hands back to the gate', (tester) async {
      final r = await pump(tester);

      await tester.tap(find.text('Restore account'));
      await tester.pumpAndSettle();

      expect(r.repo.cancellations, 1);
      expect(r.restored, [1]);
      expect(r.auth.signOuts, 0);
    });

    testWidgets('a failed restore says so and lets the user through to nothing', (tester) async {
      final r = await pump(tester, failCancel: true);

      await tester.tap(find.text('Restore account'));
      await tester.pumpAndSettle();

      expect(r.repo.cancellations, 1);
      expect(r.restored, isEmpty, reason: 'a restore the server refused must not open the app');
      expect(find.textContaining('could not be restored'), findsOneWidget);

      // And the buttons work again, so the user can retry.
      await tester.tap(find.text('Restore account'));
      await tester.pumpAndSettle();
      expect(r.repo.cancellations, 2);
    });

    testWidgets('Keep deleting signs out and does not touch the deletion', (tester) async {
      final r = await pump(tester);

      await tester.tap(find.text('Keep deleting and sign out'));
      await tester.pumpAndSettle();

      expect(r.auth.signOuts, 1);
      expect(r.repo.cancellations, 0);
      expect(r.restored, isEmpty);
    });
  });

  group('ProfileGate', () {
    /// A gate whose profile row is [rows] in turn, one per read, so a test can
    /// say what the server holds before and after a restore.
    Future<({List<ProfileGateRow> signedIn, _FakeAccountRepository repo, List<int> reads})> pumpGate(
      WidgetTester tester,
      List<ProfileGateRow> rows,
    ) async {
      final signedIn = <ProfileGateRow>[];
      final reads = <int>[];
      final repo = _FakeAccountRepository();
      await tester.pumpWidget(MaterialApp(
        home: ProfileGate(
          userId: 'me',
          load: (_) async {
            reads.add(1);
            return rows[(reads.length - 1).clamp(0, rows.length - 1)];
          },
          onSignedIn: (row) async => signedIn.add(row),
          home: (_) => const Text('HOME'),
          pendingDeletion: (requestedAt, onRestored) => PendingDeletionScreen(
            deletionRequestedAt: requestedAt,
            onRestored: onRestored,
            repository: repo,
            auth: _FakeAuthService(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (signedIn: signedIn, repo: repo, reads: reads);
    }

    final pending = ProfileGateRow(
      onboarded: true,
      pushConsent: false,
      locationConsent: false,
      notificationTz: 'Europe/Athens',
      deletionRequestedAt: _requestedAt,
    );
    const active = ProfileGateRow(
      onboarded: true,
      pushConsent: true,
      locationConsent: false,
      notificationTz: 'Europe/Athens',
    );

    testWidgets('a pending deletion stops at the restore screen, and nothing is registered', (tester) async {
      final g = await pumpGate(tester, [pending]);

      expect(find.text(_headline), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
      expect(
        g.signedIn,
        isEmpty,
        reason: 'no device registration and no time zone write for an account on its way out',
      );
    });

    testWidgets('restoring re-reads the row and opens the app, wiring notifications then', (tester) async {
      final g = await pumpGate(tester, [pending, active]);

      await tester.tap(find.text('Restore account'));
      await tester.pumpAndSettle();

      expect(g.repo.cancellations, 1);
      // The gate trusts the re-read, not the button: it asked the server again.
      expect(g.reads, hasLength(2));
      expect(find.text('HOME'), findsOneWidget);
      expect(g.signedIn, hasLength(1));
      expect(g.signedIn.single.pushConsent, isTrue);
    });

    testWidgets('a restore the server did not apply keeps the user on the restore screen', (tester) async {
      // cancelDeletion "succeeds" but the row still carries deleted_at.
      final g = await pumpGate(tester, [pending, pending]);

      await tester.tap(find.text('Restore account'));
      await tester.pumpAndSettle();

      expect(g.reads, hasLength(2));
      expect(find.text(_headline), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
    });

    testWidgets('an active account goes straight in', (tester) async {
      final g = await pumpGate(tester, [active]);

      expect(find.text('HOME'), findsOneWidget);
      expect(find.text(_headline), findsNothing);
      expect(g.signedIn, hasLength(1));
    });

    test('reads deleted_at and notification_tz off the profile row', () {
      final row = ProfileGateRow.fromRow({
        'onboarding_completed_at': '2026-10-01T10:00:00Z',
        'push_consent': false,
        'location_consent': false,
        'notification_tz': 'Europe/London',
        'deleted_at': '2026-10-21T12:30:00Z',
      });

      expect(row.onboarded, isTrue);
      expect(row.notificationTz, 'Europe/London');
      expect(row.deletionRequestedAt!.isAtSameMomentAs(DateTime.utc(2026, 10, 21, 12, 30)), isTrue);

      expect(ProfileGateRow.fromRow({'onboarding_completed_at': null}).deletionRequestedAt, isNull);
    });
  });
}
