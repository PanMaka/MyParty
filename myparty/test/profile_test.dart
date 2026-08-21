import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/party_repository.dart';
import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/data/social_repository.dart';
import 'package:myparty/models/hosted_parties.dart';
import 'package:myparty/models/party_summary.dart';
import 'package:myparty/models/profile.dart';
import 'package:myparty/models/profile_stats.dart';
import 'package:myparty/ui/screens/profile_screen.dart';
import 'package:myparty/ui/widgets/diagonal_placeholder.dart';
import 'package:myparty/ui/widgets/follow_button.dart';
import 'package:myparty/ui/widgets/profile_party_card.dart';

/// Stands in for the real repository. Subclasses rather than implements so it
/// stays in sync with the real constructor, and overrides every method that
/// touches the network — `ProfileRepository` resolves its client lazily, so no
/// Supabase client is ever constructed here.
///
/// Nothing here fakes `fetchPrivacy`, and that absence is an assertion. The
/// tiers moved to `SettingsScreen`, so the profile screen must not fetch them
/// any more — if it starts again, the real method runs, reaches for a Supabase
/// client that does not exist under `flutter test`, and the suite says so.
class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository({
    ProfileStats? stats,
    this.profile = _defaultProfile,
    this.failLoad = false,
  }) : _stats = stats ?? _defaultStats;

  static const _defaultStats = ProfileStats(partiesAttended: 7, partiesHosted: 3, storiesPosted: 12);

  /// Counters chosen not to collide with the stat tiles (7 / 3 / 12), so a
  /// `findsOneWidget` on either cannot pass by matching the other.
  ///
  /// Carries a bio and an avatar so the header has both optional halves to
  /// render; the tests that care about their absence pass an explicit profile.
  static const _defaultProfile = Profile(
    id: 'me',
    username: 'nikos',
    followerCount: 42,
    followingCount: 9,
    bio: 'Στα δεκαπέντε λεπτά από παντού.',
    avatarPath: 'me/avatar.jpg',
  );

  /// Null models both "no such row" and "the SELECT policy filtered it".
  final Profile? profile;
  final bool failLoad;

  final ProfileStats _stats;

  /// Every path the header asked Storage to resolve.
  ///
  /// Asserting on this rather than on the rendered `Image` is the point: a
  /// widget that interpolated `/object/public/avatars/<path>` itself would draw
  /// an identical circle and still be the bug — the bucket's policy decides how
  /// its objects are reached, so the call has to leave the widget layer. See
  /// [ProfileRepository.avatarUrl].
  final List<String> avatarUrlRequests = [];

  @override
  String? get currentUserId => 'me';

  @override
  Future<Profile?> fetchProfile({String? userId}) async {
    if (failLoad) throw Exception('offline');
    return profile;
  }

  @override
  Future<ProfileStats> fetchStats({String? userId}) async => _stats;

  /// Stands in for `storage.from('avatars').getPublicUrl(path)`. The host is
  /// deliberately unresolvable: `flutter_test` answers every request with a 400
  /// anyway, so this exercises the `errorBuilder` fallback rather than pretending
  /// a real object exists.
  @override
  String? avatarUrl(String? path) {
    if (path == null) return null;
    avatarUrlRequests.add(path);
    return 'https://stub.invalid/avatars/$path';
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
    this.mineUpcoming = const [],
    this.minePast = const [],
    this.hostedPublicPast = const [],
    this.covers = const {},
    this.fail = false,
    this.failCovers = false,
  });

  /// The two groups `get_my_hosted_parties` would return, already split — the
  /// fake stands in for the RPC, not for the SQL, so the split arrives
  /// pre-made exactly as it does from the server.
  final List<PartySummary> mineUpcoming;
  final List<PartySummary> minePast;

  final List<PartySummary> hostedPublicPast;

  /// party id -> signed URL, as [signedCoverUrls] returns it.
  final Map<String, String> covers;

  final bool fail;

  /// Signing failing while the LIST succeeds. A separate flag because the two
  /// have to be able to fail independently: a cover that will not sign must
  /// cost a placeholder, not the list.
  final bool failCovers;

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
    // Only the PAST window is still reached: the owner's list moved to
    // fetchMyHostedParties, so the one caller left is the other profile's
    // public section. `hostedQueries` still records the window, so a
    // regression that starts asking for upcoming here is visible.
    return window == PartyWindow.upcoming ? const [] : hostedPublicPast;
  }

  /// Every list handed to [signedCoverUrls], so a test can assert the screen
  /// asked for covers once rather than per card.
  final List<List<String>> coverRequests = [];

  @override
  Future<HostedParties> fetchMyHostedParties() async {
    if (fail) throw Exception('offline');
    return HostedParties(upcoming: mineUpcoming, past: minePast);
  }

  @override
  Future<Map<String, String>> signedCoverUrls(
    List<PartySummary> parties, {
    int expiresIn = 3600,
  }) async {
    coverRequests.add(parties.map((p) => p.id).toList());
    if (failCovers) throw Exception('storage down');
    return covers;
  }
}

PartySummary _party(
  String id,
  String title, {
  DateTime? startsAt,
  int goingCount = 0,
  int? maxCapacity,
  bool isPrivate = false,
  String? area,
  String? coverPath,
}) {
  return PartySummary(
    id: id,
    title: title,
    startsAt: startsAt ?? DateTime(2026, 9, 8, 22, 30),
    isPrivate: isPrivate,
    goingCount: goingCount,
    interestedCount: 0,
    maxCapacity: maxCapacity,
    area: area,
    coverPath: coverPath,
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

/// The party list runs well below the fold, and the screen's `ListView` only
/// builds the children it needs — so an off-screen card is genuinely absent
/// from the tree, not merely invisible. Every assertion about one has to scroll
/// first or it would fail for the wrong reason.
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
      expect(find.text('ΑΚΟΛΟΥΘΟΙ'), findsOneWidget);
      expect(find.text('φίλοι'), findsNothing);
      expect(find.text('ακόλουθοι'), findsNothing);
    });

    testWidgets('renders exactly two lines of text: the handle and the bio', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      expect(find.text('@nikos'), findsOneWidget);
      expect(find.text('Στα δεκαπέντε λεπτά από παντού.'), findsOneWidget);

      // `following_count` used to be a third thing in this block. It is not
      // rendered anywhere now — 9 is the fake's followingCount, and 42 is the
      // one follower number that survives, in the ΑΚΟΛΟΥΘΟΙ tile.
      expect(find.text('9'), findsNothing);
      expect(find.text('ακολουθεί'), findsNothing);
    });

    testWidgets('a profile with no bio renders one line, not a blank second one', (tester) async {
      await _pumpProfile(
        tester,
        _FakeProfileRepository(
          profile: const Profile(id: 'me', username: 'nikos', followerCount: 0, followingCount: 0),
        ),
      );

      // Every account looks like this the day it is created, so this is the
      // common case rather than the degraded one. Nothing may be substituted
      // in that slot: a generated sentence where a bio goes reads as the user's
      // own words.
      expect(find.text('@nikos'), findsOneWidget);
      expect(find.text(''), findsNothing);
      expect(find.textContaining('Γράψε κάτι'), findsNothing);
      expect(find.textContaining('Χωρίς bio'), findsNothing);
    });

    testWidgets('invents no display name, school or department', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      // No display_name, no school and no department column exist, so the
      // handle plus the user's own bio is the whole of the identity. A
      // placeholder in any of those slots would be a fabricated claim about a
      // real person rendered where an authoritative one goes.
      expect(find.textContaining('ΕΚΠΑ'), findsNothing);
      expect(find.textContaining('Ψυχολογία'), findsNothing);
      expect(find.textContaining('Τμήμα'), findsNothing);

      // Scoped to the handle rather than asserting no '·' anywhere on screen:
      // the ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ card is still mock copy that legitimately contains
      // one ('Απόψε · 18/24 δέχτηκαν'), so the broad form would fail for a
      // reason that has nothing to do with the header.
      expect(find.textContaining('@nikos ·'), findsNothing);
    });

    testWidgets('resolves the avatar through the repository, not by path convention', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpProfile(tester, repo);

      // The rule is not "an image appears" — it is that the URL came from
      // Storage. `avatars` is public today and private buckets need a signed
      // URL with a lifetime; a widget building the path itself would keep
      // compiling on the day that changes.
      expect(repo.avatarUrlRequests, ['me/avatar.jpg']);
    });

    testWidgets('falls back to the placeholder when avatar_path is null', (tester) async {
      final repo = _FakeProfileRepository(
        profile: const Profile(id: 'me', username: 'nikos', followerCount: 0, followingCount: 0),
      );
      await _pumpProfile(tester, repo);

      // Null means "no avatar" and nothing else, so nothing is asked of
      // Storage and the uuid-keyed gradient is drawn instead — visibly not a
      // photograph, rather than a stock face that would read as one.
      expect(repo.avatarUrlRequests, isEmpty);
      expect(find.byType(DiagonalStripePlaceholder), findsWidgets);
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
      // filtered it or it is not there at all. Same argument now covers the
      // tiles, which is why they are gated on a loaded profile rather than
      // defaulting the counts to zero.
      expect(find.text('Το προφίλ δεν είναι διαθέσιμο'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(find.text('ΑΚΟΛΟΥΘΟΙ'), findsNothing);
      expect(find.text('ΔΙΟΡΓΑΝΩΣΕ'), findsNothing);
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

      // The owner's own pair renders instead, in the public preview too: the
      // action row switches on the ProfileTarget's TYPE and deliberately
      // ignores previewingPublicView, because previewing your public profile
      // does not make you a stranger to yourself.
      expect(find.text('Διοργάνωσε πάρτι'), findsOneWidget);
      expect(find.text('Επεξεργασία προφίλ'), findsOneWidget);
    });

    testWidgets('another user gets the relationship actions', (tester) async {
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        target: const OtherProfile('someone-else'),
      );

      expect(find.byType(FollowButton), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      expect(find.text('Μήνυμα'), findsOneWidget);

      // And never the owner's pair. There is no bool that could put these on
      // somebody else's profile — the switch is over the sealed type, so the
      // two cases are exhaustive and mutually exclusive by construction.
      expect(find.text('Διοργάνωσε πάρτι'), findsNothing);
      expect(find.text('Επεξεργασία προφίλ'), findsNothing);
    });

    testWidgets('another user never gets the owner sections', (tester) async {
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        target: const OtherProfile('someone-else'),
      );

      // The settings live a screen away now, so what must be absent here is
      // the door to them: the gear opens YOUR privacy tiers, YOUR consents and
      // YOUR account deletion, and it is reached from a screen showing
      // somebody else's name.
      expect(find.byIcon(Icons.settings_outlined), findsNothing);

      // And there is no second view of someone else's profile to toggle to.
      expect(find.text('ΕΓΩ'), findsNothing);
      expect(find.text('ΔΗΜΟΣΙΑ'), findsNothing);
    });
  });

  group('the settings gear', () {
    testWidgets('opens the settings screen', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      // No scrolling: the point of the move is that these controls are one tap
      // from the top of the tab, rather than under however many parties you
      // have hosted.
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Ρυθμίσεις'), findsOneWidget);
    });

    testWidgets('survives the public preview', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      await tester.tap(find.text('ΔΗΜΟΣΙΑ'));
      await tester.pumpAndSettle();

      // Previewing your public profile does not make you a stranger to
      // yourself — the same reasoning that keeps the owner's action row on
      // screen in this state.
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    });

    testWidgets('the owner sections themselves are gone from the tab', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      // Not "below the fold" — absent. `scrollUntilVisible` would run to the
      // end of the list and throw if any of these were merely off-screen, so
      // findsNothing here is a real claim about the tree.
      expect(find.text('ΙΔΙΩΤΙΚΟΤΗΤΑ'), findsNothing);
      expect(find.text('ΕΙΔΟΠΟΙΗΣΕΙΣ'), findsNothing);
      expect(find.text('ΛΟΓΑΡΙΑΣΜΟΣ'), findsNothing);
      expect(find.text('Αποσύνδεση'), findsNothing);
    });
  });

  group('the party list', () {
    _FakePartyRepository twoGroups() => _FakePartyRepository(
      mineUpcoming: [_party('p1', 'Ταράτσα Θησείου', area: 'Θησείο')],
      minePast: [_party('p2', 'Kápsimo'), _party('p3', 'Εξάρχεια')],
    );

    testWidgets('is one list under one heading, grouped in two', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(), parties: twoGroups());
      await _scrollTo(tester, find.text('ΔΙΟΡΓΑΝΩΝΩ'));

      expect(find.text('ΔΙΟΡΓΑΝΩΝΩ'), findsOneWidget);
      expect(find.text('ΠΕΡΑΣΜΕΝΑ'), findsOneWidget);

      // The two headings this replaced.
      expect(find.text('ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ'), findsNothing);
      expect(find.text('ΤΟ ΙΣΤΟΡΙΚΟ ΜΟΥ'), findsNothing);
    });

    testWidgets('counts what it renders, and nothing else', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(), parties: twoGroups());
      await _scrollTo(tester, find.text('ΠΑΡΤΙ · 3'));

      // 1 upcoming + 2 past. The number in the heading is derived from the two
      // rendered lists rather than counted separately, so it cannot drift from
      // the cards beneath it — including when the RPC's limit truncates.
      expect(find.text('ΠΑΡΤΙ · 3'), findsOneWidget);
      expect(find.byType(ProfilePartyCard), findsNWidgets(3));
    });

    testWidgets('never prints a count it has not finished checking', (tester) async {
      // Pumped without settling: the future is still in flight.
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileScreen(
            repository: _FakeProfileRepository(),
            social: _FakeSocialRepository(),
            parties: twoGroups(),
          ),
        ),
      );
      await tester.pump();

      // "ΠΑΡΤΙ · 0" over a spinner asserts that the user hosts nothing, which
      // on a slow connection would be the first thing they read.
      expect(find.text('ΠΑΡΤΙ · 0'), findsNothing);

      await tester.pumpAndSettle();
    });

    testWidgets('labels each card with what the party is to you', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(), parties: twoGroups());
      await _scrollTo(tester, find.text('Ταράτσα Θησείου'));

      expect(find.text('διοργανώνεις'), findsOneWidget);
      expect(find.text('διοργάνωσες'), findsNWidgets(2));
    });

    testWidgets('draws the privacy badge and the area, and skips an absent area', (tester) async {
      final parties = _FakePartyRepository(
        mineUpcoming: [
          _party('p1', 'Ιδιωτικό', isPrivate: true, area: 'Κουκάκι'),
          _party('p2', 'Χωρίς περιοχή'),
        ],
      );
      await _pumpProfile(tester, _FakeProfileRepository(), parties: parties);
      await _scrollTo(tester, find.text('Ιδιωτικό'));

      expect(find.text('ΙΔΙΩΤΙΚΟ'), findsOneWidget);
      expect(find.text('ΔΗΜΟΣΙΟ'), findsOneWidget);
      expect(find.textContaining('Κουκάκι'), findsOneWidget);

      // area is nullable and there is no derivation available — reverse
      // geocoding parties.location would hand a private party's coordinates to
      // a geocoder. An absent area draws nothing, not a trailing separator.
      expect(find.textContaining('· null'), findsNothing);
    });

    testWidgets('asks for every cover in one request, keyed by party', (tester) async {
      final parties = _FakePartyRepository(
        mineUpcoming: [_party('p1', 'Με εξώφυλλο', coverPath: 'p1/cover.jpg')],
        minePast: [_party('p2', 'Και άλλο', coverPath: 'p2/cover.jpg')],
        covers: {'p1': 'https://stub.invalid/p1', 'p2': 'https://stub.invalid/p2'},
      );
      await _pumpProfile(tester, _FakeProfileRepository(), parties: parties);

      // One call for the whole list, not one per card: party-covers is private,
      // so each URL is a signature, and signing them individually would be a
      // round trip per row.
      expect(parties.coverRequests, [
        ['p1', 'p2'],
      ]);
    });

    testWidgets('a failed signing costs placeholders, not the list', (tester) async {
      final parties = _FakePartyRepository(
        mineUpcoming: [_party('p1', 'Με εξώφυλλο', coverPath: 'p1/cover.jpg')],
        failCovers: true,
      );
      await _pumpProfile(tester, _FakeProfileRepository(), parties: parties);
      await _scrollTo(tester, find.text('Με εξώφυλλο'));

      // The card is still there. Losing the images costs decoration; losing
      // the list costs the content.
      expect(find.text('Με εξώφυλλο'), findsOneWidget);
      expect(find.text('Δεν φόρτωσαν τα πάρτι σου'), findsNothing);
    });

    testWidgets('an empty group says so without emptying the other', (tester) async {
      final parties = _FakePartyRepository(minePast: [_party('p2', 'Kápsimo')]);
      await _pumpProfile(tester, _FakeProfileRepository(), parties: parties);
      await _scrollTo(tester, find.text('Δεν διοργανώνεις κάποιο πάρτι αυτή τη στιγμή.'));

      expect(find.text('Δεν διοργανώνεις κάποιο πάρτι αυτή τη στιγμή.'), findsOneWidget);
      expect(find.text('Kápsimo'), findsOneWidget);
      expect(find.text('ΠΑΡΤΙ · 1'), findsOneWidget);
    });

    testWidgets('hosting nothing at all is one absence, not two', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(), parties: _FakePartyRepository());
      await _scrollTo(tester, find.text('Δεν έχεις διοργανώσει πάρτι ακόμα.'));

      expect(find.text('Δεν έχεις διοργανώσει πάρτι ακόμα.'), findsOneWidget);

      // Two group headings over two empty notices would make an account that
      // has never hosted look like a screen that failed twice.
      expect(find.text('ΔΙΟΡΓΑΝΩΝΩ'), findsNothing);
      expect(find.text('ΠΕΡΑΣΜΕΝΑ'), findsNothing);
      expect(find.text('Ταράτσα στο Κουκάκι'), findsNothing);
    });

    testWidgets('a failed load says so rather than showing nothing', (tester) async {
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        parties: _FakePartyRepository(fail: true),
      );
      await _scrollTo(tester, find.text('Δεν φόρτωσαν τα πάρτι σου'));

      // One request behind the list, so one error — a per-group failure would
      // be describing a fetch that does not happen.
      expect(find.text('Δεν φόρτωσαν τα πάρτι σου'), findsOneWidget);
      expect(find.byType(ProfilePartyCard), findsNothing);
    });

    testWidgets('is never asked about another user', (tester) async {
      final parties = _FakePartyRepository(mineUpcoming: [_party('p1', 'Δικό μου')]);
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        parties: parties,
        target: const OtherProfile('someone-else'),
      );

      // get_my_hosted_parties takes no user id, so it can only ever answer
      // about auth.uid(). Rendering it under somebody else's name would put my
      // parties behind their handle — which is why the other profile keeps its
      // own narrower, hosted-and-public section instead.
      expect(find.text('Δικό μου'), findsNothing);
      expect(find.text('ΔΙΟΡΓΑΝΩΝΩ'), findsNothing);
      expect(find.textContaining('ΠΑΡΤΙ · '), findsNothing);
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
    testWidgets('are the two the layout calls for, sourced from the row and the RPC', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      // followerCount off the profiles row, partiesHosted off
      // get_profile_stats. Two tiles, two numbers.
      expect(find.text('ΑΚΟΛΟΥΘΟΙ'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('ΔΙΟΡΓΑΝΩΣΕ'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      // The design-prototype literals this phase replaced.
      expect(find.text('47'), findsNothing);
      expect(find.text('5'), findsNothing);
      expect(find.text('312'), findsNothing);
    });

    testWidgets('drop the three counters that have no tile, rather than showing them small', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      // 7 = partiesAttended, 12 = storiesPosted, 9 = followingCount. All three
      // are still fetched and still on ProfileStats/Profile; none is rendered.
      // Chosen as a decision, not an oversight — a half-size fourth number
      // under two large tiles is the shape this layout exists to avoid.
      expect(find.text('7'), findsNothing);
      expect(find.text('12'), findsNothing);
      expect(find.text('9'), findsNothing);
      expect(find.text('πάρτι φέτος'), findsNothing);
      expect(find.text('stories'), findsNothing);
    });

    testWidgets('are the same two tiles for every viewer', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());
      expect(find.text('ΑΚΟΛΟΥΘΟΙ'), findsOneWidget);
      expect(find.text('ΔΙΟΡΓΑΝΩΣΕ'), findsOneWidget);

      await tester.tap(find.text('ΔΗΜΟΣΙΑ'));
      await tester.pumpAndSettle();

      // Nothing in this row is viewer-dependent any more. The tile that was —
      // "πάρτι φέτος", structurally zero for anyone but the owner because
      // get_profile_stats runs with invoker rights over an owner-scoped rsvps
      // policy — is gone, so the row's shape no longer encodes who is looking.
      expect(find.text('ΑΚΟΛΟΥΘΟΙ'), findsOneWidget);
      expect(find.text('ΔΙΟΡΓΑΝΩΣΕ'), findsOneWidget);
    });
  });
}
