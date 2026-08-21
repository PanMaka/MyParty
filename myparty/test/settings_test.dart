import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/models/profile_privacy.dart';
import 'package:myparty/ui/screens/settings_screen.dart';

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
  );

  final bool failWrites;

  ProfilePrivacy _privacy;

  /// Every wire value the screen actually sent, in order. Asserting on `.wire`
  /// rather than on the enum is deliberate: the string is what the database
  /// sees, and a mismatch with the `map_visibility`/`invite_policy` enum types
  /// is a 22P02 at runtime that no amount of Dart type-checking would catch.
  final List<String> mapVisibilityWrites = [];
  final List<String> invitePolicyWrites = [];

  @override
  String? get currentUserId => 'me';

  @override
  Future<ProfilePrivacy?> fetchPrivacy() async {
    if (gate != null) await gate!.future;
    return _privacy;
  }

  @override
  Future<void> updatePrivacy({MapVisibility? mapVisibility, InvitePolicy? invitePolicy}) async {
    if (mapVisibility != null) mapVisibilityWrites.add(mapVisibility.wire);
    if (invitePolicy != null) invitePolicyWrites.add(invitePolicy.wire);

    // Rejected exactly as the server would reject it: nothing is stored. The
    // screen must not end up displaying the value it tried to write.
    if (failWrites) throw Exception('rejected');

    _privacy = _privacy.copyWith(mapVisibility: mapVisibility, invitePolicy: invitePolicy);
  }
}

Future<void> _pumpSettings(WidgetTester tester, _FakeProfileRepository repo) async {
  await tester.pumpWidget(MaterialApp(home: SettingsScreen(repository: repo)));
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
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  group('layout', () {
    testWidgets('gathers every owner control the profile tab used to trail', (tester) async {
      await _pumpSettings(tester, _FakeProfileRepository());

      // The three sections, in the order the screen argues for: preferences,
      // then consent, then the irreversible one.
      expect(find.text('ΙΔΙΩΤΙΚΟΤΗΤΑ'), findsOneWidget);
      expect(find.text('ΕΙΔΟΠΟΙΗΣΕΙΣ'), findsOneWidget);
      expect(find.text('ΛΟΓΑΡΙΑΣΜΟΣ'), findsOneWidget);

      // And every row that used to trail the profile tab. All six are asserted
      // here because this is now the ONLY screen they exist on — a row dropped
      // in the move would otherwise be invisible to the whole suite.
      expect(find.text('Ποιος βλέπει σε ποια πάρτι πάω'), findsOneWidget);
      expect(find.text('Ποιος βλέπει τα πάρτι μου στον χάρτη'), findsOneWidget);
      expect(find.text('Ποιος μπορεί να με καλέσει'), findsOneWidget);
      expect(find.text('Ειδοποιήσεις & τοποθεσία'), findsOneWidget);

      await _scrollTo(tester, find.text('Αποσύνδεση'));
      expect(find.text('Δεδομένα & διαγραφή'), findsOneWidget);
      expect(find.text('Αποσύνδεση'), findsOneWidget);
    });

    testWidgets('says so when the tiers do not load, rather than loading forever', (tester) async {
      // The real repository, reached because nothing was injected: under
      // `flutter test` there is no Supabase client, so fetchPrivacy throws.
      // That is the offline case, and the row has to admit it — an eternal "…"
      // reads as a broken app, and a tier rendered as a guess is worse than
      // either.
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Δεν φόρτωσε'), findsNWidgets(2));
      expect(find.text('…'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('privacy rows', () {
    testWidgets('show the loaded tiers rather than the old hardcoded copy', (tester) async {
      await _pumpSettings(tester, _FakeProfileRepository());

      expect(find.text('Όλοι'), findsOneWidget);
      expect(find.text('Οποιοσδήποτε'), findsOneWidget);

      // Copy from the design prototype that described a friendship model the
      // schema does not have.
      expect(find.text('Φίλοι και φίλοι φίλων'), findsNothing);
      expect(find.text('Οι φίλοι βλέπουν πού είσαι απόψε'), findsNothing);
    });

    testWidgets('choosing a map tier writes the enum wire value', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpSettings(tester, repo);

      await tester.tap(find.text('Ποιος βλέπει τα πάρτι μου στον χάρτη'));
      await tester.pumpAndSettle();

      // The sheet explains what each tier does — a tier list with only labels
      // would be guessable at best.
      expect(_sheetOption('Όσοι με ακολουθούν'), findsOneWidget);
      expect(find.textContaining('Όσοι έχουν πρόσκληση'), findsOneWidget);

      await tester.tap(_sheetOption('Κανείς'));
      await tester.pumpAndSettle();

      expect(repo.mapVisibilityWrites, ['private']);
      expect(repo.invitePolicyWrites, isEmpty);
      expect(find.text('Κανείς'), findsOneWidget);
    });

    testWidgets('choosing the same tier again writes nothing', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpSettings(tester, repo);

      await tester.tap(find.text('Ποιος μπορεί να με καλέσει'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetOption('Οποιοσδήποτε'));
      await tester.pumpAndSettle();

      expect(repo.invitePolicyWrites, isEmpty);
    });

    testWidgets('choosing an invite policy writes the enum wire value', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpSettings(tester, repo);

      await tester.tap(find.text('Ποιος μπορεί να με καλέσει'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetOption('Μόνο όσους ακολουθώ'));
      await tester.pumpAndSettle();

      expect(repo.invitePolicyWrites, ['following']);
      expect(repo.mapVisibilityWrites, isEmpty);
      expect(find.text('Μόνο όσους ακολουθώ'), findsOneWidget);
    });

    testWidgets('a rejected write leaves the row showing the stored value', (tester) async {
      final repo = _FakeProfileRepository(failWrites: true);
      await _pumpSettings(tester, repo);

      await tester.tap(find.text('Ποιος βλέπει τα πάρτι μου στον χάρτη'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetOption('Κανείς'));
      await tester.pumpAndSettle();

      // It was attempted...
      expect(repo.mapVisibilityWrites, ['private']);
      // ...and the row reloaded to what the server actually holds. A privacy
      // control that displays a setting the server never stored is worse than
      // one that fails loudly — the user would believe they were hidden.
      expect(find.text('Όλοι'), findsOneWidget);
      expect(find.text('Κανείς'), findsNothing);
    });

    testWidgets('a row with nothing loaded yet is not tappable', (tester) async {
      final gate = Completer<void>();
      final repo = _FakeProfileRepository(gate: gate);
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(repository: repo)));
      await tester.pump();

      // fetchPrivacy is still in flight, so the row is showing "…". Tapping it
      // now would open a tier sheet with no current tier to check against —
      // `_privacy!` — which is a crash on exactly the slow connection that
      // makes the window wide enough to hit.
      expect(find.text('…'), findsNWidgets(2));
      await tester.tap(find.text('Ποιος βλέπει τα πάρτι μου στον χάρτη'));
      await tester.pump();

      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Όλοι'), findsOneWidget);
    });
  });
}
