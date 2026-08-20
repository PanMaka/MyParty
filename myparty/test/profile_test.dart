import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/party_repository.dart';
import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/data/social_repository.dart';
import 'package:myparty/models/party_summary.dart';
import 'package:myparty/models/profile.dart';
import 'package:myparty/models/profile_privacy.dart';
import 'package:myparty/models/profile_stats.dart';
import 'package:myparty/ui/screens/profile_screen.dart';
import 'package:myparty/ui/widgets/follow_button.dart';

/// Stands in for the real repository. Subclasses rather than implements so it
/// stays in sync with the real constructor, and overrides every method that
/// touches the network — `ProfileRepository` resolves its client lazily, so no
/// Supabase client is ever constructed here.
class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository({
    ProfilePrivacy? privacy,
    ProfileStats? stats,
    this.failWrites = false,
    this.profile = _defaultProfile,
    this.failLoad = false,
  }) : _privacy = privacy ?? _defaultPrivacy,
       _stats = stats ?? _defaultStats;

  static const _defaultPrivacy = ProfilePrivacy(
    mapVisibility: MapVisibility.public,
    invitePolicy: InvitePolicy.anyone,
  );

  static const _defaultStats = ProfileStats(partiesAttended: 7, partiesHosted: 3, storiesPosted: 12);

  /// Counters chosen not to collide with the stat tiles (7 / 3 / 12), so a
  /// `findsOneWidget` on either cannot pass by matching the other.
  static const _defaultProfile = Profile(
    id: 'me',
    username: 'nikos',
    followerCount: 42,
    followingCount: 9,
  );

  final bool failWrites;

  /// Null models both "no such row" and "the SELECT policy filtered it".
  final Profile? profile;
  final bool failLoad;

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
  Future<Profile?> fetchProfile({String? userId}) async {
    if (failLoad) throw Exception('offline');
    return profile;
  }

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

/// The ΑΚΟΛΟΥΘΕΙ rail now loads on the owner's public preview as well, so a
/// [SocialRepository] method actually runs during these tests — it never did
/// before, which is why only the profile repository used to be injected.
class _FakeSocialRepository extends SocialRepository {
  _FakeSocialRepository({this.following = const []});

  final List<Profile> following;

  @override
  Future<List<Profile>> fetchFollowing({String? userId}) async => following;
}

/// [PartyRepository] had to move to a lazily-resolved client before this was
/// possible -- it was the last repository still building one in its
/// constructor, which is why nothing had ever faked a party.
class _FakePartyRepository extends PartyRepository {
  _FakePartyRepository({
    this.hosting = const [],
    this.hostedPublicPast = const [],
    this.attended = const [],
    this.fail = false,
  });

  final List<PartySummary> hosting;
  final List<PartySummary> hostedPublicPast;
  final List<PartySummary> attended;
  final bool fail;

  /// Every (window, publicOnly) pair the screen actually asked for. The public
  /// section's `publicOnly: true` is the whole difference between "parties they
  /// hosted that were public" and "parties they hosted that you happen to be
  /// allowed to see", so it is asserted rather than assumed.
  final List<String> hostedQueries = [];

  @override
  Future<List<PartySummary>> fetchHostedParties({
    String? hostId,
    required PartyWindow window,
    bool publicOnly = false,
    int limit = 12,
  }) async {
    hostedQueries.add('${window.name}:publicOnly=$publicOnly');
    if (fail) throw Exception('offline');
    return window == PartyWindow.upcoming ? hosting : hostedPublicPast;
  }

  @override
  Future<List<PartySummary>> fetchAttendedParties({int limit = 50}) async {
    if (fail) throw Exception('offline');
    return attended;
  }
}

PartySummary _party(
  String id,
  String title, {
  DateTime? startsAt,
  int goingCount = 0,
  int? maxCapacity,
  bool isPrivate = false,
}) {
  return PartySummary(
    id: id,
    title: title,
    startsAt: startsAt ?? DateTime(2026, 9, 8, 22, 30),
    isPrivate: isPrivate,
    goingCount: goingCount,
    interestedCount: 0,
    maxCapacity: maxCapacity,
  );
}

Future<void> _pumpProfile(
  WidgetTester tester,
  _FakeProfileRepository repo, {
  ProfileTarget target = const OwnProfile(),
  List<Profile> following = const [],
  _FakePartyRepository? parties,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ProfileScreen(
        target: target,
        repository: repo,
        social: _FakeSocialRepository(following: following),
        parties: parties ?? _FakePartyRepository(),
      ),
    ),
  );
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
  group('header', () {
    testWidgets('renders the profiles row, not the prototype identity', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      expect(find.text('@nikos'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);

      // The design-prototype literals this step replaced.
      expect(find.text('Κατερίνα Βλάχου'), findsNothing);
      expect(find.text('@katerina · ΕΚΠΑ, Ψυχολογία'), findsNothing);
      expect(find.text('184'), findsNothing);
      expect(find.text('23'), findsNothing);
    });

    testWidgets('labels the follower count followers, never friends', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      // There is no friendships table and none is to be added — the graph is
      // follows-only and asymmetric. "φίλοι" named a mutual, consented edge
      // over a number that is neither.
      expect(find.text('ακόλουθοι'), findsOneWidget);
      expect(find.text('ακολουθεί'), findsOneWidget);
      expect(find.text('φίλοι'), findsNothing);
    });

    testWidgets('invents no display name or school', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      // No display_name column and no school column exist, so the handle is
      // the whole of the identity. A placeholder here would be a fabricated
      // claim about a real person rendered in the authoritative slot.
      expect(find.textContaining('ΕΚΠΑ'), findsNothing);
      expect(find.textContaining('Ψυχολογία'), findsNothing);

      // Scoped to the handle rather than asserting no '·' anywhere on screen:
      // the ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ card is still mock copy that legitimately contains
      // one ('Απόψε · 18/24 δέχτηκαν'), so the broad form would fail for a
      // reason that has nothing to do with the header.
      expect(find.textContaining('@nikos ·'), findsNothing);
    });

    testWidgets('a failed load offers a retry rather than an empty header', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(failLoad: true));

      expect(find.text('Δεν φόρτωσε το προφίλ'), findsOneWidget);
      expect(find.text('Δοκίμασε ξανά'), findsOneWidget);
      expect(find.text('@nikos'), findsNothing);
    });

    testWidgets('a filtered or missing row says so instead of rendering zeros', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(profile: null));

      // Rendering "@" with 0/0 would assert that an account exists and has no
      // followers, when what actually happened is that the SELECT policy
      // filtered it or it is not there at all.
      expect(find.text('Το προφίλ δεν είναι διαθέσιμο'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });
  });

  group('self vs other', () {
    testWidgets('the owner never sees a follow button or a report menu', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      // Not even in the public preview, which is the state the old
      // `bool _selfView` + nullable id combination could not rule out.
      await tester.tap(find.text('ΔΗΜΟΣΙΑ'));
      await tester.pumpAndSettle();

      expect(find.byType(FollowButton), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.text('Μήνυμα'), findsNothing);
    });

    testWidgets('another user gets the relationship actions', (tester) async {
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        target: const OtherProfile('someone-else'),
      );

      expect(find.byType(FollowButton), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    });

    testWidgets('another user never gets the owner sections', (tester) async {
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        target: const OtherProfile('someone-else'),
      );

      // fetchPrivacy is self-only, so these rows on somebody else's profile
      // would be showing the VIEWER's tiers under their name. Same for the
      // sign-out button and the account-deletion row.
      expect(find.text('Ποιος βλέπει τα πάρτι μου στον χάρτη'), findsNothing);
      expect(find.text('Αποσύνδεση'), findsNothing);
      expect(find.text('Δεδομένα & διαγραφή'), findsNothing);

      // And there is no second view of someone else's profile to toggle to.
      expect(find.text('ΕΓΩ'), findsNothing);
      expect(find.text('ΔΗΜΟΣΙΑ'), findsNothing);
    });
  });

  group('hosted parties', () {
    testWidgets('the ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ card renders real parties', (tester) async {
      final parties = _FakePartyRepository(
        hosting: [_party('p1', 'Ταράτσα Θησείου', goingCount: 18, maxCapacity: 24)],
      );
      await _pumpProfile(tester, _FakeProfileRepository(), parties: parties);
      await _scrollTo(tester, find.text('Ταράτσα Θησείου'));

      expect(find.text('Ταράτσα Θησείου'), findsOneWidget);
      expect(find.textContaining('18/24 θέσεις'), findsOneWidget);

      // The prototype's party, and the button that had no screen behind it.
      expect(find.text('Ταράτσα στο Κουκάκι'), findsNothing);
      expect(find.text('Διαχείριση'), findsNothing);
    });

    testWidgets('a party with no capacity shows a count, not a ratio', (tester) async {
      final parties = _FakePartyRepository(
        hosting: [_party('p1', 'Χωρίς όριο', goingCount: 7)],
      );
      await _pumpProfile(tester, _FakeProfileRepository(), parties: parties);
      await _scrollTo(tester, find.text('Χωρίς όριο'));

      // max_capacity is nullable and is the only real denominator a party has.
      // Inventing one to divide by is what the hardcoded 0.75 bar did.
      expect(find.textContaining('7 δηλώσεις συμμετοχής'), findsOneWidget);
      expect(find.byType(FractionallySizedBox), findsNothing);
    });

    testWidgets('hosting nothing renders an empty state, not a fake party', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(), parties: _FakePartyRepository());
      await _scrollTo(tester, find.text('Δεν διοργανώνεις κάποιο πάρτι αυτή τη στιγμή.'));

      expect(find.text('Δεν διοργανώνεις κάποιο πάρτι αυτή τη στιγμή.'), findsOneWidget);
      expect(find.text('Ταράτσα στο Κουκάκι'), findsNothing);
    });

    testWidgets('a failed load says so rather than showing nothing', (tester) async {
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        parties: _FakePartyRepository(fail: true),
      );
      await _scrollTo(tester, find.text('Δεν φόρτωσαν τα πάρτι σου'));

      expect(find.text('Δεν φόρτωσαν τα πάρτι σου'), findsOneWidget);
    });
  });

  group('history strip', () {
    testWidgets('renders past parties you attended', (tester) async {
      final parties = _FakePartyRepository(
        attended: [_party('a1', 'Kápsimo'), _party('a2', 'Εξάρχεια')],
      );
      await _pumpProfile(tester, _FakeProfileRepository(), parties: parties);
      await _scrollTo(tester, find.text('Kápsimo'));

      expect(find.text('Kápsimo'), findsOneWidget);
      expect(find.text('Εξάρχεια'), findsOneWidget);
      // The third prototype tile had no party behind it at all.
      expect(find.text('Anodos'), findsNothing);
    });

    testWidgets('no history renders an empty state', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(), parties: _FakePartyRepository());
      await _scrollTo(tester, find.text('Δεν έχεις πάει ακόμα σε κάποιο πάρτι.'));

      expect(find.text('Δεν έχεις πάει ακόμα σε κάποιο πάρτι.'), findsOneWidget);
    });
  });

  group('public hosted parties', () {
    testWidgets('renders real past public parties', (tester) async {
      final parties = _FakePartyRepository(
        hostedPublicPast: [
          _party('h1', 'Rooftop Αυγούστου', startsAt: DateTime(2025, 8, 9), goingCount: 140),
        ],
      );
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        target: const OtherProfile('someone-else'),
        parties: parties,
      );
      await _scrollTo(tester, find.text('Rooftop Αυγούστου'));

      expect(find.text('Rooftop Αυγούστου'), findsOneWidget);
      expect(find.textContaining('140 ήρθαν'), findsOneWidget);
      // The year is printed because the party is not from this year.
      expect(find.textContaining('9 Αύγ 2025'), findsOneWidget);

      expect(find.text('Rooftop Σεπτεμβρίου'), findsNothing);
      // "Κουκάκι" had no column behind it -- parties.location is a point.
      expect(find.textContaining('Κουκάκι'), findsNothing);
    });

    testWidgets('asks for public parties specifically, not merely visible ones', (tester) async {
      final parties = _FakePartyRepository();
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        target: const OtherProfile('someone-else'),
        parties: parties,
      );

      // RLS already hides parties this viewer may not see -- but it would let
      // through a PRIVATE party they hold an invitation to, which under a
      // heading reading "public parties" would misdescribe it.
      expect(parties.hostedQueries, contains('past:publicOnly=true'));
      expect(parties.hostedQueries, isNot(contains('past:publicOnly=false')));
    });

    testWidgets('no public parties renders an empty state', (tester) async {
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        target: const OtherProfile('someone-else'),
        parties: _FakePartyRepository(),
      );
      await _scrollTo(tester, find.text('Κανένα δημόσιο πάρτι ακόμα.'));

      expect(find.text('Κανένα δημόσιο πάρτι ακόμα.'), findsOneWidget);
    });
  });

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
