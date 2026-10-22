import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/models/profile.dart';
import 'package:myparty/ui/screens/auth_gate.dart';
import 'package:myparty/ui/screens/name_notice_screen.dart';

/// Phase 49: a name stored before names became public stays owner-only until
/// its owner answers the notice. These tests pin the copy, both answers, and
/// where the gate puts the notice.
class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository({this.fail = false});

  final bool fail;
  int acknowledged = 0;
  int cleared = 0;

  @override
  Future<void> acknowledgeNameShown() async {
    acknowledged++;
    if (fail) throw Exception('offline');
  }

  @override
  Future<void> clearNames() async {
    cleared++;
    if (fail) throw Exception('offline');
  }
}

Future<({_FakeProfileRepository repo, List<int> answered})> _pumpNotice(
  WidgetTester tester, {
  bool fail = false,
}) async {
  final repo = _FakeProfileRepository(fail: fail);
  final answered = <int>[];
  await tester.pumpWidget(MaterialApp(
    home: NameNoticeScreen(name: 'Νίκος Παπαδόπουλος', onAnswered: () => answered.add(1), repository: repo),
  ));
  return (repo: repo, answered: answered);
}

void main() {
  group('NameNoticeScreen', () {
    testWidgets('says the name is now shown, whose name, and where to change it', (tester) async {
      await _pumpNotice(tester);

      expect(find.text('Your name is now shown on your profile.'), findsOneWidget);
      expect(
        find.text('People signed in to MyParty will see Νίκος Παπαδόπουλος under your username. '
            'You can change it in Edit profile.'),
        findsOneWidget,
      );
      expect(
        find.text('Until now only you could see your name, and nobody else sees it until you tap OK.'),
        findsOneWidget,
      );
      expect(find.text('OK'), findsOneWidget);
      expect(find.text('Remove my name'), findsOneWidget);
    });

    testWidgets('OK acknowledges, and only then lets the user through', (tester) async {
      final n = await _pumpNotice(tester);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(n.repo.acknowledged, 1);
      expect(n.repo.cleared, 0);
      expect(n.answered, [1]);
    });

    testWidgets('Remove my name deletes it, and lets the user through', (tester) async {
      final n = await _pumpNotice(tester);

      await tester.tap(find.text('Remove my name'));
      await tester.pumpAndSettle();

      expect(n.repo.cleared, 1);
      expect(n.repo.acknowledged, 0);
      expect(n.answered, [1]);
    });

    testWidgets('a failed answer stays on the screen and says so', (tester) async {
      final n = await _pumpNotice(tester, fail: true);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Something went wrong. Check your connection and try again.'), findsOneWidget);

      await tester.tap(find.text('Remove my name'));
      await tester.pumpAndSettle();
      expect(find.text('Your name was not removed. Check your connection and try again.'), findsOneWidget);

      expect(n.answered, isEmpty, reason: 'nothing the server did not take lets the user through');
    });
  });

  group('ProfileGate', () {
    Future<List<ProfileGateRow>> pumpGate(WidgetTester tester, ProfileGateRow row) async {
      final signedIn = <ProfileGateRow>[];
      await tester.pumpWidget(MaterialApp(
        home: ProfileGate(
          userId: 'me',
          load: (_) async => row,
          onSignedIn: (r) async => signedIn.add(r),
          home: (_) => const Text('HOME'),
          pendingDeletion: (_, _) => const Text('PENDING'),
          nameNotice: (name, onAnswered) => NameNoticeScreen(
            name: name,
            onAnswered: onAnswered,
            repository: _FakeProfileRepository(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return signedIn;
    }

    const owed = ProfileGateRow(
      onboarded: true,
      pushConsent: false,
      locationConsent: false,
      unshownName: 'Άρης Βλάχος',
    );

    testWidgets('an unshown name stops at the notice, and an answer opens the app', (tester) async {
      await pumpGate(tester, owed);

      expect(find.text(NameNoticeScreen.headline), findsOneWidget);
      expect(find.text('HOME'), findsNothing);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('no notice owed goes straight home', (tester) async {
      await pumpGate(tester, const ProfileGateRow(onboarded: true, pushConsent: false, locationConsent: false));

      expect(find.text('HOME'), findsOneWidget);
      expect(find.text(NameNoticeScreen.headline), findsNothing);
    });

    testWidgets('a pending deletion is asked first', (tester) async {
      await pumpGate(
        tester,
        ProfileGateRow(
          onboarded: true,
          pushConsent: false,
          locationConsent: false,
          deletionRequestedAt: DateTime(2026, 10, 20),
          unshownName: 'Άρης Βλάχος',
        ),
      );

      expect(find.text('PENDING'), findsOneWidget);
      expect(find.text(NameNoticeScreen.headline), findsNothing);
    });

    test('the row owes the notice only for a stored, unshown name', () {
      final settings = {'onboarding_completed_at': '2026-10-01T10:00:00Z'};

      expect(
        ProfileGateRow.fromRow(settings, names: {'first_name': 'Άρης', 'last_name': 'Βλάχος', 'shown': false})
            .unshownName,
        'Άρης Βλάχος',
      );
      expect(
        ProfileGateRow.fromRow(settings, names: {'first_name': 'Άρης', 'last_name': 'Βλάχος', 'shown': true})
            .unshownName,
        isNull,
      );
      expect(ProfileGateRow.fromRow(settings).unshownName, isNull, reason: 'no name, nothing to announce');
    });
  });

  group('Profile names', () {
    Map<String, dynamic> row(Object? names) => {
          'id': 'u',
          'username': 'maria',
          'follower_count': 0,
          'following_count': 0,
          'user_names': names,
        };

    test('reads the user_names embed into a full name', () {
      final p = Profile.fromRow(row({'first_name': 'Μαρία', 'last_name': 'Κωνσταντίνου'}));
      expect(p.fullName, 'Μαρία Κωνσταντίνου');
    });

    test('a null embed (no name, unshown, pending, blocked) has no name', () {
      expect(Profile.fromRow(row(null)).fullName, isNull);
      expect(Profile.fromRow({...row(null)}..remove('user_names')).fullName, isNull);
    });

    test('names are both or neither', () {
      expect(PersonNameConstraint.validatePair('', ''), (first: null, last: null));
      expect(PersonNameConstraint.validatePair('Ana', 'Pap'), (first: null, last: null));
      expect(PersonNameConstraint.validatePair('Ana', '').last, 'Add your last name too, or leave both empty.');
      expect(PersonNameConstraint.validatePair('', 'Pap').first, 'Add your first name too, or leave both empty.');
      expect(PersonNameConstraint.validatePair('a' * 51, 'Pap').first, 'Up to 50 characters.');
    });
  });
}
