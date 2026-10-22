import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/models/gender.dart';
import 'package:myparty/models/profile_privacy.dart';
import 'package:myparty/services/auth_service.dart';
import 'package:myparty/ui/screens/change_email_screen.dart';
import 'package:myparty/ui/screens/change_password_screen.dart';
import 'package:myparty/utils/auth_messages.dart';
import 'package:myparty/ui/screens/settings_screen.dart';
import 'package:myparty/utils/app_info.dart';

/// Stands in for the real repository. Subclasses rather than implements so it
/// stays in sync with the real constructor, and overrides every method that
/// touches the network — `ProfileRepository` resolves its client lazily, so no
/// Supabase client is ever constructed here.
class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository({ProfilePrivacy? privacy, this.failWrites = false, this.gate})
    : _privacy = privacy ?? _defaultPrivacy;

  /// Holds `fetchPrivacy` open so a test can look at the screen while the tiers
  /// are still in flight. Without it the fake resolves inside a single `pump`,
  /// which makes the loading state unobservable and the row's null guard
  /// untestable — the bug it guards against (`_privacy!` on a tap that beat the
  /// fetch) is precisely a race with a slow network.
  final Completer<void>? gate;

  static const _defaultPrivacy = ProfilePrivacy(
    mapVisibility: MapVisibility.public,
    invitePolicy: InvitePolicy.anyone,
    dmPolicy: DmPolicy.everyone,
  );

  final bool failWrites;

  ProfilePrivacy _privacy;

  /// Every wire value the screen actually sent, in order. Asserting on `.wire`
  /// rather than on the enum is deliberate: the string is what the database
  /// sees, and a mismatch with the `map_visibility`/`invite_policy` enum types
  /// is a 22P02 at runtime that no amount of Dart type-checking would catch.
  final List<String> mapVisibilityWrites = [];
  final List<String> invitePolicyWrites = [];
  final List<String> dmPolicyWrites = [];
  final List<bool> suggestAccountWrites = [];

  /// The stored answer, as `user_genders` would return it; and every value
  /// `set_my_gender` was sent, null being "prefer not to say".
  Gender gender = Gender.female;
  final List<String?> genderWrites = [];

  @override
  String? get currentUserId => 'me';

  @override
  Future<Gender?> fetchMyGender() async => gender;

  @override
  Future<void> setGender(Gender gender) async {
    genderWrites.add(gender.wire);
    if (failWrites) throw Exception('rejected');
    this.gender = gender;
  }

  @override
  Future<ProfilePrivacy?> fetchPrivacy() async {
    if (gate != null) await gate!.future;
    return _privacy;
  }

  @override
  Future<void> updatePrivacy({
    MapVisibility? mapVisibility,
    InvitePolicy? invitePolicy,
    DmPolicy? dmPolicy,
    bool? suggestAccount,
  }) async {
    if (mapVisibility != null) mapVisibilityWrites.add(mapVisibility.wire);
    if (invitePolicy != null) invitePolicyWrites.add(invitePolicy.wire);
    if (dmPolicy != null) dmPolicyWrites.add(dmPolicy.wire);
    if (suggestAccount != null) suggestAccountWrites.add(suggestAccount);

    // Rejected exactly as the server would reject it: nothing is stored. The
    // screen must not end up displaying the value it tried to write.
    if (failWrites) throw Exception('rejected');

    _privacy = _privacy.copyWith(
      mapVisibility: mapVisibility,
      invitePolicy: invitePolicy,
      dmPolicy: dmPolicy,
      suggestAccount: suggestAccount,
    );
  }
}

/// Records sign-outs instead of reaching for a Supabase client.
class _FakeAuthService extends AuthService {
  _FakeAuthService({this.email = 'me@example.com'});

  String? email;
  int signOuts = 0;

  @override
  String? get currentEmail => email;

  String? pending;

  @override
  String? get pendingNewEmail => pending;

  @override
  Future<void> signOut() async => signOuts++;

  final passwordWrites = <String>[];

  @override
  Future<bool> verifyPassword({required String email, required String password}) async => true;

  @override
  Future<void> writePassword({required String currentPassword, required String newPassword}) async =>
      passwordWrites.add(newPassword);
}

Future<String> _version() async => '1.2.3 (45)';

Future<void> _pumpSettings(
  WidgetTester tester,
  _FakeProfileRepository repo, {
  _FakeAuthService? auth,
  Future<bool> Function(Uri)? openUrl,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: SettingsScreen(
      repository: repo,
      auth: auth ?? _FakeAuthService(),
      appVersion: _version,
      openUrl: openUrl ?? (_) async => true,
    ),
  ));
  await tester.pumpAndSettle();
}

/// An option label inside the open sheet. Scoped rather than bare, because the
/// CURRENT tier's label is on screen twice while the sheet is open — once as the
/// row's subtitle underneath and once as the option itself — and a bare
/// `find.text` is ambiguous for exactly the case that matters (re-picking the
/// value you already have).
Finder _sheetOption(String label) =>
    find.descendant(of: find.byType(BottomSheet), matching: find.text(label));

/// The last two sections sit just past the bottom of the 800x600 test surface,
/// and a `ListView` only builds the children it needs — so an off-screen row is
/// genuinely absent from the tree rather than merely invisible.
/// The value shown on ONE tier row. Needed since Phase 33: the map row and the
/// messages row both default to "Everyone", so a bare `find.text` can no
/// longer say which row it is reading.
Finder _tierValue(String rowTitle, String value) => find.descendant(
      of: find.ancestor(of: find.text(rowTitle), matching: find.byType(InkWell)),
      matching: find.text(value),
    );

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

/// Taps a settings row by its title, scrolling it on screen first: since
/// Phase 43 the privacy rows sit below ACCOUNT and PROFILE, partly past the
/// bottom of the 800x600 test surface.
Future<void> _tapRow(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title));
  await tester.pumpAndSettle();
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

void main() {
  group('layout', () {
    testWidgets('five sections, in order, each holding its rows', (tester) async {
      await _pumpSettings(tester, _FakeProfileRepository());

      // Every section and every row, because this is the ONLY screen they
      // exist on: a row dropped in a reshuffle would otherwise be invisible
      // to the whole suite. Scrolled to one by one, since a ListView builds
      // only what is near the viewport.
      const expected = [
        'ACCOUNT', 'Email', 'Password', 'Data & deletion',
        'PROFILE', 'Edit profile', 'Gender', genderVisibilityNote,
        'PRIVACY & SAFETY', 'Who sees my parties on the map', 'Who can invite me',
        'Who can message me', 'Suggest my account to others', 'Blocked accounts',
        'NOTIFICATIONS', 'Notifications & location',
        'SUPPORT & LEGAL', 'Contact support', 'Open-source licences', 'App version',
        'Sign out',
      ];
      double? lastY;
      for (final label in expected) {
        await _scrollTo(tester, find.text(label));
        expect(find.text(label), findsOneWidget, reason: label);
        // Order, not just presence: each label sits below the previous one in
        // the list's own coordinates (screen y plus how far it has scrolled).
        final scrolled = tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
        final y = tester.getTopLeft(find.text(label)).dy + scrolled;
        if (lastY != null) expect(y, greaterThan(lastY), reason: '$label is out of order');
        lastY = y;
      }

      // The old section names are gone, not duplicated.
      expect(find.text('PRIVACY'), findsNothing);
      expect(find.text('ABOUT YOU'), findsNothing);
    });

    testWidgets('the unbuilt "who sees which parties I go to" row is gone, not "coming soon"', (tester) async {
      await _pumpSettings(tester, _FakeProfileRepository());
      for (final label in ['ACCOUNT', 'PRIVACY & SAFETY', 'SUPPORT & LEGAL', 'Sign out']) {
        await _scrollTo(tester, find.text(label));
        expect(find.text('Who sees which parties I go to'), findsNothing);
        expect(find.textContaining('Coming soon'), findsNothing);
      }
    });

    testWidgets('nothing on the screen offers analytics', (tester) async {
      await _pumpSettings(tester, _FakeProfileRepository());
      // Checked at every scroll stop, so a row anywhere in the list is caught.
      for (final label in ['ACCOUNT', 'PRIVACY & SAFETY', 'SUPPORT & LEGAL', 'Sign out']) {
        await _scrollTo(tester, find.text(label));
        expect(find.textContaining(RegExp('analytic', caseSensitive: false)), findsNothing);
      }
    });

    testWidgets('says so when the tiers do not load, rather than loading forever', (tester) async {
      // The real repository, reached because nothing was injected: under
      // `flutter test` there is no Supabase client, so fetchPrivacy throws.
      // That is the offline case, and the row has to admit it — an eternal "…"
      // reads as a broken app, and a tier rendered as a guess is worse than
      // either.
      // Tall enough for the gender row and all three tier rows at once.
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(auth: _FakeAuthService(), appVersion: _version)));
      await tester.pumpAndSettle();

      // Three tier rows (map, invites, messages), the "Suggest my account"
      // switch (same get_my_settings read), and the gender row, which reads a
      // different table and fails on its own.
      expect(find.text('Did not load'), findsNWidgets(5));
      expect(find.text('…'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('privacy rows', () {
    testWidgets('show the loaded tiers rather than the old hardcoded copy', (tester) async {
      await _pumpSettings(tester, _FakeProfileRepository());

      expect(_tierValue('Who sees my parties on the map', 'Everyone'), findsOneWidget);
      expect(find.text('Anyone'), findsOneWidget);
      expect(_tierValue('Who can message me', 'Everyone'), findsOneWidget);

      // Copy from the design prototype that described a friendship model the
      // schema does not have.
      expect(find.text('Friends and friends of friends'), findsNothing);
      expect(find.text('Your friends see where you are tonight'), findsNothing);
    });

    testWidgets('choosing a map tier writes the enum wire value', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpSettings(tester, repo);

      await _tapRow(tester, 'Who sees my parties on the map');

      // The sheet explains what each tier does — a tier list with only labels
      // would be guessable at best.
      expect(_sheetOption('People who follow me'), findsOneWidget);
      expect(find.textContaining('People holding an invitation'), findsOneWidget);

      await tester.tap(_sheetOption('Nobody'));
      await tester.pumpAndSettle();

      expect(repo.mapVisibilityWrites, ['private']);
      expect(repo.invitePolicyWrites, isEmpty);
      expect(find.text('Nobody'), findsOneWidget);
    });

    testWidgets('choosing the same tier again writes nothing', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpSettings(tester, repo);

      await _tapRow(tester, 'Who can invite me');
      await tester.tap(_sheetOption('Anyone'));
      await tester.pumpAndSettle();

      expect(repo.invitePolicyWrites, isEmpty);
    });

    testWidgets('choosing an invite policy writes the enum wire value', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpSettings(tester, repo);

      await _tapRow(tester, 'Who can invite me');
      await tester.tap(_sheetOption('Only people I follow'));
      await tester.pumpAndSettle();

      expect(repo.invitePolicyWrites, ['following']);
      expect(repo.mapVisibilityWrites, isEmpty);
      expect(find.text('Only people I follow'), findsOneWidget);
    });

    testWidgets('a rejected write leaves the row showing the stored value', (tester) async {
      final repo = _FakeProfileRepository(failWrites: true);
      await _pumpSettings(tester, repo);

      await _tapRow(tester, 'Who sees my parties on the map');
      await tester.tap(_sheetOption('Nobody'));
      await tester.pumpAndSettle();

      // It was attempted...
      expect(repo.mapVisibilityWrites, ['private']);
      // ...and the row reloaded to what the server actually holds. A privacy
      // control that displays a setting the server never stored is worse than
      // one that fails loudly — the user would believe they were hidden.
      expect(_tierValue('Who sees my parties on the map', 'Everyone'), findsOneWidget);
      expect(find.text('Nobody'), findsNothing);
    });

    testWidgets('a row with nothing loaded yet is not tappable', (tester) async {
      final gate = Completer<void>();
      final repo = _FakeProfileRepository(gate: gate);
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(repository: repo, auth: _FakeAuthService(), appVersion: _version),
      ));
      await tester.pump();
      // PRIVACY & SAFETY is below ACCOUNT and PROFILE now.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pump();

      // fetchPrivacy is still in flight, so the row is showing "…". Tapping it
      // now would open a tier sheet with no current tier to check against —
      // `_privacy!` — which is a crash on exactly the slow connection that
      // makes the window wide enough to hit. Four: the three tiers and the
      // "Suggest my account" switch, which is disabled for the same reason.
      expect(find.text('…'), findsNWidgets(4));
      await tester.tap(find.text('Who sees my parties on the map'));
      await tester.pump();

      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);

      gate.complete();
      await tester.pumpAndSettle();
      expect(_tierValue('Who sees my parties on the map', 'Everyone'), findsOneWidget);
    });

    testWidgets('choosing who can message me writes the enum wire value', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpSettings(tester, repo);

      await _tapRow(tester, 'Who can message me');

      // Both things the tiers do NOT do are said where the choice is made.
      expect(find.textContaining('already replied in stay open'), findsOneWidget);
      expect(find.textContaining('Blocking someone always stops them'), findsOneWidget);
      expect(_sheetOption('Only people I follow'), findsOneWidget);

      await tester.tap(_sheetOption('Nobody'));
      await tester.pumpAndSettle();

      expect(repo.dmPolicyWrites, ['nobody']);
      expect(repo.mapVisibilityWrites, isEmpty);
      expect(repo.invitePolicyWrites, isEmpty);
      expect(_tierValue('Who can message me', 'Nobody'), findsOneWidget);
    });
  });
  group('suggest my account', () {
    Finder suggestSwitch() => find.descendant(
          of: find.ancestor(of: find.text('Suggest my account to others'), matching: find.byType(Row)).first,
          matching: find.byType(Switch),
        );

    testWidgets('shows the stored value and writes the flip', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpSettings(tester, repo);
      await _scrollTo(tester, find.text('Suggest my account to others'));

      expect(tester.widget<Switch>(suggestSwitch()).value, isTrue, reason: 'default on, as stored');
      expect(find.text('Shows you in People you may know. People can still find you by searching.'),
          findsOneWidget);

      await tester.tap(suggestSwitch());
      await tester.pumpAndSettle();
      expect(repo.suggestAccountWrites, [false]);
      expect(tester.widget<Switch>(suggestSwitch()).value, isFalse, reason: 'reads back the stored false');
    });

    testWidgets('a rejected write leaves the switch on the stored value', (tester) async {
      final repo = _FakeProfileRepository(failWrites: true);
      await _pumpSettings(tester, repo);
      await _scrollTo(tester, find.text('Suggest my account to others'));

      await tester.tap(suggestSwitch());
      await tester.pumpAndSettle();
      expect(repo.suggestAccountWrites, [false]);
      expect(tester.widget<Switch>(suggestSwitch()).value, isTrue);
    });

    testWidgets('disabled while the setting is still loading, not guessed', (tester) async {
      final gate = Completer<void>();
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          repository: _FakeProfileRepository(gate: gate),
          auth: _FakeAuthService(),
          appVersion: _version,
          openUrl: (_) async => true,
        ),
      ));
      await tester.pump();
      await _scrollTo(tester, find.text('Suggest my account to others'));
      expect(tester.widget<Switch>(suggestSwitch()).onChanged, isNull);
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(suggestSwitch()).onChanged, isNotNull);
    });
  });

  group('gender', () {
    testWidgets('the row shows the stored answer, with the note directly under it', (tester) async {
      // All on the first screen, with no scrolling: the gender row, its note
      // and the heading of the next section.
      await _pumpSettings(tester, _FakeProfileRepository());

      expect(_tierValue('Gender', 'Female'), findsOneWidget);
      expect(find.text(genderVisibilityNote), findsOneWidget);
      // In PROFILE now, with the note directly under its card: below the
      // Gender row, above PRIVACY & SAFETY.
      expect(
        tester.getTopLeft(find.text(genderVisibilityNote)).dy,
        greaterThan(tester.getTopLeft(find.text('Gender')).dy),
      );
      expect(
        tester.getTopLeft(find.text('PRIVACY & SAFETY')).dy,
        greaterThan(tester.getTopLeft(find.text(genderVisibilityNote)).dy),
      );
    });

    testWidgets('"Prefer not to say" clears the answer: null on the wire', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpSettings(tester, repo);
      await _scrollTo(tester, find.text('Gender'));

      await tester.tap(find.text('Gender'));
      await tester.pumpAndSettle();
      // The note is said where the choice is made, too.
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text(genderVisibilityNote)), findsOneWidget);

      await tester.tap(_sheetOption('Prefer not to say'));
      await tester.pumpAndSettle();

      expect(repo.genderWrites, [null]);
      expect(_tierValue('Gender', 'Prefer not to say'), findsOneWidget);
    });

    testWidgets('an answer is written as its enum value; the same one again writes nothing', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpSettings(tester, repo);
      await _scrollTo(tester, find.text('Gender'));

      await tester.tap(find.text('Gender'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetOption('Female'));
      await tester.pumpAndSettle();
      expect(repo.genderWrites, isEmpty);

      await tester.tap(find.text('Gender'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetOption('Non-binary'));
      await tester.pumpAndSettle();
      expect(repo.genderWrites, ['non_binary']);
      expect(_tierValue('Gender', 'Non-binary'), findsOneWidget);
    });

    testWidgets('a rejected write leaves the row showing the stored answer', (tester) async {
      final repo = _FakeProfileRepository(failWrites: true);
      await _pumpSettings(tester, repo);
      await _scrollTo(tester, find.text('Gender'));

      await tester.tap(find.text('Gender'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetOption('Male'));
      await tester.pumpAndSettle();

      expect(repo.genderWrites, ['male']);
      expect(_tierValue('Gender', 'Female'), findsOneWidget);
    });
  });

  group('account', () {
    testWidgets('shows the signed-in email, and opens Change email (Phase 47)', (tester) async {
      await _pumpSettings(tester, _FakeProfileRepository(), auth: _FakeAuthService(email: 'ada@example.com'));

      expect(find.text('ada@example.com'), findsOneWidget);
      await tester.tap(find.text('ada@example.com'));
      await tester.pumpAndSettle();
      expect(find.byType(ChangeEmailScreen), findsOneWidget);
    });

    testWidgets('a change waiting for confirmation is shown on the row', (tester) async {
      final auth = _FakeAuthService(email: 'ada@example.com')..pending = 'ada@new.example';
      await _pumpSettings(tester, _FakeProfileRepository(), auth: auth);

      expect(find.text('ada@example.com → ada@new.example (waiting for confirmation)'), findsOneWidget);
    });

    testWidgets('a completed change comes back with the snackbar and the new address', (tester) async {
      final auth = _FakeAuthService(email: 'ada@example.com');
      await _pumpSettings(tester, _FakeProfileRepository(), auth: auth);

      await tester.tap(find.text('ada@example.com'));
      await tester.pumpAndSettle();
      // What ChangeEmailScreen pops with once both codes are in; the session
      // then reports the new address.
      auth.email = 'ada@new.example';
      Navigator.of(tester.element(find.byType(ChangeEmailScreen))).pop('ada@new.example');
      await tester.pumpAndSettle();

      expect(find.text(emailChangedMessage('ada@new.example')), findsOneWidget);
      expect(find.text('ada@new.example'), findsOneWidget);
    });

    testWidgets('Password opens Change password, and a change lands back here with the snackbar', (tester) async {
      final auth = _FakeAuthService();
      await _pumpSettings(tester, _FakeProfileRepository(), auth: auth);

      await tester.tap(find.text('Password'));
      await tester.pumpAndSettle();
      expect(find.byType(ChangePasswordScreen), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Current password'), 'old-Password!');
      await tester.enterText(find.widgetWithText(TextField, 'New password'), 'fresh-Password!');
      await tester.enterText(find.widgetWithText(TextField, 'Confirm new password'), 'fresh-Password!');
      await tester.pump();
      await tester.tap(find.byKey(changePasswordSubmitKey));
      await tester.pumpAndSettle();

      expect(auth.passwordWrites, ['fresh-Password!']);
      expect(find.byType(ChangePasswordScreen), findsNothing);
      expect(find.text('ACCOUNT'), findsOneWidget);
      // Shown by Settings, because the screen that knew has popped.
      expect(find.text(passwordChangedMessage), findsOneWidget);
    });

    testWidgets('sign out asks first, and Cancel signs nobody out', (tester) async {
      final auth = _FakeAuthService();
      await _pumpSettings(tester, _FakeProfileRepository(), auth: auth);
      await _scrollTo(tester, find.text('Sign out'));

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out?'), findsOneWidget);
      expect(auth.signOuts, 0, reason: 'the dialog is a gate, not a formality');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(auth.signOuts, 0);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Sign out')));
      await tester.pumpAndSettle();
      expect(auth.signOuts, 1);
    });
  });

  group('support & legal', () {
    testWidgets('shows the app version', (tester) async {
      await _pumpSettings(tester, _FakeProfileRepository());
      await _scrollTo(tester, find.text('App version'));

      expect(find.text('1.2.3 (45)'), findsOneWidget);
    });

    testWidgets('contact support opens a mailto to the support address, with the version', (tester) async {
      final opened = <Uri>[];
      await _pumpSettings(tester, _FakeProfileRepository(), openUrl: (uri) async {
        opened.add(uri);
        return true;
      });
      await _scrollTo(tester, find.text('Contact support'));

      await tester.tap(find.text('Contact support'));
      await tester.pumpAndSettle();

      expect(opened, hasLength(1));
      expect(opened.single.scheme, 'mailto');
      expect(opened.single.path, supportEmail);
      expect(Uri.decodeComponent(opened.single.query), contains('MyParty 1.2.3 (45)'));
      // Encoded as %20, not '+', which mail apps would print literally.
      expect(opened.single.query, isNot(contains('+')));
    });

    testWidgets('with no mail app, contact support says where to write', (tester) async {
      await _pumpSettings(tester, _FakeProfileRepository(), openUrl: (_) async => false);
      await _scrollTo(tester, find.text('Contact support'));

      await tester.tap(find.text('Contact support'));
      await tester.pump();

      expect(find.text('No email app found. Write to us at $supportEmail'), findsOneWidget);
    });

    testWidgets('open-source licences opens the licence page', (tester) async {
      await _pumpSettings(tester, _FakeProfileRepository());
      await _scrollTo(tester, find.text('Open-source licences'));

      await tester.tap(find.text('Open-source licences'));
      await tester.pumpAndSettle();

      expect(find.byType(LicensePage), findsOneWidget);
    });
  });
}
