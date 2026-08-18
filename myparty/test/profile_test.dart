import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/models/profile_privacy.dart';
import 'package:myparty/models/profile_stats.dart';
import 'package:myparty/ui/screens/profile_screen.dart';

/// Stands in for the real repository. Subclasses rather than implements so it
/// stays in sync with the real constructor, and overrides every method that
/// touches the network — `ProfileRepository` resolves its client lazily, so no
/// Supabase client is ever constructed here.
class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository({ProfilePrivacy? privacy, ProfileStats? stats, this.failWrites = false})
    : _privacy = privacy ?? _defaultPrivacy,
      _stats = stats ?? _defaultStats;

  static const _defaultPrivacy = ProfilePrivacy(
    mapVisibility: MapVisibility.public,
    invitePolicy: InvitePolicy.anyone,
  );

  static const _defaultStats = ProfileStats(partiesAttended: 7, partiesHosted: 3, storiesPosted: 12);

  final bool failWrites;

  ProfilePrivacy _privacy;
  final ProfileStats _stats;

  /// Every wire value the screen actually sent, in order. Asserting on `.wire`
  /// rather than on the enum is deliberate: the string is what the database
  /// sees, and a mismatch with the `map_visibility`/`invite_policy` enum types
  /// is a 22P02 at runtime that no amount of Dart type-checking would catch.
  final List<String> mapVisibilityWrites = [];
  final List<String> invitePolicyWrites = [];

  @override
  String? get currentUserId => 'me';

  @override
  Future<ProfilePrivacy?> fetchPrivacy() async => _privacy;

  @override
  Future<ProfileStats> fetchStats({String? userId}) async => _stats;

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

Future<void> _pumpProfile(WidgetTester tester, _FakeProfileRepository repo) async {
  await tester.pumpWidget(MaterialApp(home: ProfileScreen(repository: repo)));
  await tester.pumpAndSettle();
}

/// The ΙΔΙΩΤΙΚΟΤΗΤΑ card sits well below the fold, and the screen's `ListView`
/// only builds the children it needs — so an off-screen row is genuinely absent
/// from the tree, not merely invisible. Every privacy assertion has to scroll
/// first or it would fail for the wrong reason.
/// An option label inside the open sheet. Scoped rather than bare, because the
/// CURRENT tier's label is on screen twice while the sheet is open — once as the
/// row's subtitle underneath and once as the option itself — and a bare
/// `find.text` is ambiguous for exactly the case that matters (re-picking the
/// value you already have).
Finder _sheetOption(String label) =>
    find.descendant(of: find.byType(BottomSheet), matching: find.text(label));

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  group('stat tiles', () {
    testWidgets('render the values from get_profile_stats, not the mock strings', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      expect(find.text('7'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);

      // The design-prototype literals this phase replaced.
      expect(find.text('47'), findsNothing);
      expect(find.text('5'), findsNothing);
      expect(find.text('312'), findsNothing);
    });

    testWidgets('the attendance tile is absent in the public view', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());
      expect(find.text('πάρτι φέτος'), findsOneWidget);

      await tester.tap(find.text('ΔΗΜΟΣΙΑ'));
      await tester.pumpAndSettle();

      // get_profile_stats runs with invoker rights and the rsvps SELECT policy
      // is owner-only, so this count is structurally zero for any other viewer.
      // Showing "0 πάρτι φέτος" would assert something false about them; the
      // tile is dropped instead.
      expect(find.text('πάρτι φέτος'), findsNothing);
      expect(find.text('διοργάνωσε'), findsOneWidget);
      expect(find.text('stories'), findsOneWidget);
    });
  });

  group('privacy rows', () {
    testWidgets('show the loaded tiers rather than the old hardcoded copy', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());
      await _scrollTo(tester, find.text('Ποιος βλέπει τα πάρτι μου στον χάρτη'));

      expect(find.text('Ποιος βλέπει τα πάρτι μου στον χάρτη'), findsOneWidget);
      expect(find.text('Όλοι'), findsOneWidget);
      expect(find.text('Ποιος μπορεί να με καλέσει'), findsOneWidget);
      expect(find.text('Οποιοσδήποτε'), findsOneWidget);

      // Copy from the design prototype that described a friendship model the
      // schema does not have.
      expect(find.text('Φίλοι και φίλοι φίλων'), findsNothing);
      expect(find.text('Οι φίλοι βλέπουν πού είσαι απόψε'), findsNothing);
    });

    testWidgets('choosing a map tier writes the enum wire value', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpProfile(tester, repo);
      await _scrollTo(tester, find.text('Ποιος βλέπει τα πάρτι μου στον χάρτη'));

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
      await _pumpProfile(tester, repo);
      await _scrollTo(tester, find.text('Ποιος μπορεί να με καλέσει'));

      await tester.tap(find.text('Ποιος μπορεί να με καλέσει'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetOption('Οποιοσδήποτε'));
      await tester.pumpAndSettle();

      expect(repo.invitePolicyWrites, isEmpty);
    });

    testWidgets('choosing an invite policy writes the enum wire value', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpProfile(tester, repo);
      await _scrollTo(tester, find.text('Ποιος μπορεί να με καλέσει'));

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
      await _pumpProfile(tester, repo);
      await _scrollTo(tester, find.text('Ποιος βλέπει τα πάρτι μου στον χάρτη'));

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
  });
}
