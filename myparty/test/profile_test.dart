import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/party_repository.dart';
import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/data/social_repository.dart';
import 'package:myparty/models/follow_suggestion.dart';
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

/// The follow button and the FOLLOWING rail on another user's profile both
/// reach a [SocialRepository], so one is injected.
class _FakeSocialRepository extends SocialRepository {
  _FakeSocialRepository({this.following = const []});

  final List<Profile> following;

  /// Every follow-graph method the screen reached for, in order.
  /// `fetchFollowing` is deliberately not recorded: it is the FOLLOWING rail's
  /// own load, and counting it here would drown the signal this list is for.
  final List<String> calls = [];

  @override
  Future<List<Profile>> fetchFollowing({String? userId}) async => following;

  /// The owner's PEOPLE YOU MAY KNOW row. Empty here, so the section stays
  /// hidden; test/follow_suggestions_test.dart covers it.
  @override
  Future<List<FollowSuggestion>> fetchFollowSuggestions({SuggestionCursor? after, int limit = 20}) async =>
      const [];

  @override
  Future<bool> isFollowing(String userId) async {
    calls.add('isFollowing:$userId');
    return false;
  }

  @override
  Future<void> insertFollow(String userId) async => calls.add('follow:$userId');

  @override
  Future<void> deleteFollow(String userId) async => calls.add('unfollow:$userId');
}

/// [PartyRepository] had to move to a lazily-resolved client before this was
/// possible -- it was the last repository still building one in its
/// constructor, which is why nothing had ever faked a party.
class _FakePartyRepository extends PartyRepository {
  /// A viewer who hosts none of the fixtures, so every party opens its sheet
  /// rather than the host dashboard.
  @override
  String? get currentUserId => 'viewer';

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

/// The follow graph as the server holds it, shared by the two fakes below so
/// that a write through one is what the other reads back — which is what makes
/// "the refetch agrees with the optimistic number" an assertion at all.
class _FollowServer {
  int followers = 42;
}

class _LiveProfileRepository extends _FakeProfileRepository {
  _LiveProfileRepository(this.server);

  final _FollowServer server;
  int fetches = 0;

  @override
  Future<Profile?> fetchProfile({String? userId}) async {
    fetches += 1;
    return Profile(id: userId ?? 'me', username: 'nikos', followerCount: server.followers, followingCount: 9);
  }
}

class _LiveSocialRepository extends _FakeSocialRepository {
  _LiveSocialRepository(this.server, {this.refuse = false});

  final _FollowServer server;
  final bool refuse;

  /// Holds the write in flight, so a test can look at the screen between the
  /// tap and the server's answer.
  Completer<void>? inFlight;

  @override
  Future<void> insertFollow(String userId) async {
    await inFlight?.future;
    if (refuse) throw Exception('blocked');
    server.followers += 1;
  }

  @override
  Future<void> deleteFollow(String userId) async {
    await inFlight?.future;
    if (refuse) throw Exception('blocked');
    server.followers -= 1;
  }
}

/// The owner's hosting as the server holds it: create_party_with_invites adds
/// the row that get_my_hosted_parties lists and get_profile_stats counts.
class _HostingProfiles extends _FakeProfileRepository {
  int hosted = 3;

  @override
  Future<ProfileStats> fetchStats({String? userId}) async =>
      ProfileStats(partiesAttended: 7, partiesHosted: hosted, storiesPosted: 12);
}

class _HostingParties extends _FakePartyRepository {
  _HostingParties(this.profiles);

  final _HostingProfiles profiles;
  final List<PartySummary> upcoming = [];

  @override
  Future<HostedParties> fetchMyHostedParties() async => HostedParties(upcoming: upcoming, past: const []);

  @override
  Future<String> insertPartyWithInvites({
    required Map<String, dynamic> party,
    List<String> inviteeIds = const [],
  }) async {
    upcoming.add(_party('new-party', party['title'] as String));
    profiles.hosted += 1;
    return 'new-party';
  }
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

      expect(find.text('nikos'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);

      // The design-prototype literals this step replaced.
      expect(find.text('Κατερίνα Βλάχου'), findsNothing);
      expect(find.text('@katerina · ΕΚΠΑ, Ψυχολογία'), findsNothing);
      expect(find.text('184'), findsNothing);
      expect(find.text('23'), findsNothing);
    });

    testWidgets('the username has no "@", and the full name sits under it, smaller and muted (Phase 49)',
        (tester) async {
      const named = Profile(
        id: 'me', username: 'nikos', followerCount: 42, followingCount: 9,
        bio: 'Στα δεκαπέντε λεπτά από παντού.',
        firstName: 'Νίκος', lastName: 'Παπαδόπουλος',
      );
      await _pumpProfile(tester, _FakeProfileRepository(profile: named));

      expect(find.text('nikos'), findsOneWidget);
      expect(find.text('@nikos'), findsNothing);
      final name = find.text('Νίκος Παπαδόπουλος');
      expect(name, findsOneWidget);

      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(top(find.text('nikos')), lessThan(top(name)), reason: 'the username stays the main line');
      expect(top(name), lessThan(top(find.text('Στα δεκαπέντε λεπτά από παντού.'))));

      final handleStyle = tester.widget<Text>(find.text('nikos')).style!;
      final nameStyle = tester.widget<Text>(name).style!;
      expect(nameStyle.fontSize, lessThan(handleStyle.fontSize!));
      expect(nameStyle.color!.a, lessThan(1), reason: 'muted');
    });

    testWidgets('no name draws nothing: the bio sits where it always did', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());
      final bioGap = tester.getTopLeft(find.text('Στα δεκαπέντε λεπτά από παντού.')).dy -
          tester.getBottomLeft(find.text('nikos')).dy;

      // The default fake has no name. With no name line, the only space between
      // handle and bio is the bio's own 5px padding.
      expect(bioGap, closeTo(5, 0.5));
    });

    testWidgets("another user's profile shows their name the same way", (tester) async {
      const other = Profile(
        id: 'u2', username: 'maria', followerCount: 1, followingCount: 1,
        firstName: 'Μαρία', lastName: 'Κωνσταντίνου',
      );
      await _pumpProfile(tester, _FakeProfileRepository(profile: other), target: const OtherProfile('u2'));

      expect(find.text('maria'), findsOneWidget);
      expect(find.text('Μαρία Κωνσταντίνου'), findsOneWidget);
    });

    testWidgets('labels the follower count followers, never friends', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      // There is no friendships table and none is to be added — the graph is
      // follows-only and asymmetric. "φίλοι" named a mutual, consented edge
      // over a number that is neither.
      expect(find.text('FOLLOWERS'), findsOneWidget);
      expect(find.text('φίλοι'), findsNothing);
      expect(find.text('ακόλουθοι'), findsNothing);
    });

    testWidgets('renders exactly two lines of text: the handle and the bio', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      expect(find.text('nikos'), findsOneWidget);
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
      expect(find.text('nikos'), findsOneWidget);
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

      expect(find.text('The profile did not load'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('nikos'), findsNothing);
    });

    testWidgets('a filtered or missing row says so instead of rendering zeros', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(profile: null));

      // Rendering "@" with 0/0 would assert that an account exists and has no
      // followers, when what actually happened is that the SELECT policy
      // filtered it or it is not there at all. Same argument now covers the
      // tiles, which is why they are gated on a loaded profile rather than
      // defaulting the counts to zero.
      expect(find.text('This profile is not available'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(find.text('FOLLOWERS'), findsNothing);
      expect(find.text('HOSTED'), findsNothing);
    });
  });

  group('self vs other', () {
    testWidgets('the owner gets their own pair, and no relationship actions', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      expect(find.text('Host a party'), findsOneWidget);
      expect(find.text('Edit profile'), findsOneWidget);

      expect(find.byType(FollowButton), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.text('Message'), findsNothing);
    });

    testWidgets('the owner has no ME / PUBLIC preview toggle', (tester) async {
      final social = _FakeSocialRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileScreen(
            repository: _FakeProfileRepository(),
            social: social,
            parties: _FakePartyRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ME'), findsNothing);
      expect(find.text('PUBLIC'), findsNothing);
      // Nor the visitor-only sections the preview used to draw on your tab.
      expect(find.text('PUBLIC PARTIES THEY HOSTED'), findsNothing);
      expect(social.calls, isEmpty);
    });

    testWidgets('another user gets the relationship actions', (tester) async {
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        target: const OtherProfile('someone-else'),
      );

      expect(find.byType(FollowButton), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      expect(find.text('Message'), findsOneWidget);

      // And never the owner's pair. There is no bool that could put these on
      // somebody else's profile — the switch is over the sealed type, so the
      // two cases are exhaustive and mutually exclusive by construction.
      expect(find.text('Host a party'), findsNothing);
      expect(find.text('Edit profile'), findsNothing);
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
      expect(find.text('ME'), findsNothing);
      expect(find.text('PUBLIC'), findsNothing);
    });
  });

  group('back button', () {
    Future<void> pumpPushed(WidgetTester tester, ProfileTarget target) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => ProfileScreen(
                      target: target,
                      repository: _FakeProfileRepository(),
                      social: _FakeSocialRepository(),
                      parties: _FakePartyRepository(),
                    ),
                  )),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('another user\'s profile, pushed, has one and it goes back', (tester) async {
      await pumpPushed(tester, const OtherProfile('someone-else'));

      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.byType(ProfileScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('the system back does the same thing', (tester) async {
      await pumpPushed(tester, const OtherProfile('someone-else'));

      // What Android's back button and back gesture dispatch.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(ProfileScreen), findsNothing);
    });

    testWidgets('the owner\'s profile as the tab root has none', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      expect(find.byType(BackButton), findsNothing);
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

      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('the owner sections themselves are gone from the tab', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      // Not "below the fold" — absent. `scrollUntilVisible` would run to the
      // end of the list and throw if any of these were merely off-screen, so
      // findsNothing here is a real claim about the tree.
      expect(find.text('PRIVACY'), findsNothing);
      expect(find.text('NOTIFICATIONS'), findsNothing);
      expect(find.text('ACCOUNT'), findsNothing);
      expect(find.text('Sign out'), findsNothing);
    });
  });

  group('the party list', () {
    _FakePartyRepository twoGroups() => _FakePartyRepository(
      mineUpcoming: [_party('p1', 'Ταράτσα Θησείου', area: 'Θησείο')],
      minePast: [_party('p2', 'Kápsimo'), _party('p3', 'Εξάρχεια')],
    );

    testWidgets('is one list under one heading, grouped in two', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(), parties: twoGroups());
      await _scrollTo(tester, find.text('HOSTING'));

      expect(find.text('HOSTING'), findsOneWidget);
      expect(find.text('PAST'), findsOneWidget);

      // The two headings this replaced.
      expect(find.text('ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ'), findsNothing);
      expect(find.text('ΤΟ ΙΣΤΟΡΙΚΟ ΜΟΥ'), findsNothing);
    });

    testWidgets('counts what it renders, and nothing else', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(), parties: twoGroups());
      await _scrollTo(tester, find.text('PARTIES · 3'));

      // 1 upcoming + 2 past. The number in the heading is derived from the two
      // rendered lists rather than counted separately, so it cannot drift from
      // the cards beneath it — including when the RPC's limit truncates.
      expect(find.text('PARTIES · 3'), findsOneWidget);
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
      expect(find.text('PARTIES · 0'), findsNothing);

      await tester.pumpAndSettle();
    });

    testWidgets('labels each card with what the party is to you', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(), parties: twoGroups());
      await _scrollTo(tester, find.text('Ταράτσα Θησείου'));

      expect(find.text('hosting'), findsOneWidget);
      expect(find.text('hosted'), findsNWidgets(2));
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

      expect(find.text('PRIVATE'), findsOneWidget);
      expect(find.text('PUBLIC'), findsOneWidget);
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
      expect(find.text('Your parties did not load'), findsNothing);
    });

    testWidgets('an empty group says so without emptying the other', (tester) async {
      final parties = _FakePartyRepository(minePast: [_party('p2', 'Kápsimo')]);
      await _pumpProfile(tester, _FakeProfileRepository(), parties: parties);
      await _scrollTo(tester, find.text('You are not hosting anything right now.'));

      expect(find.text('You are not hosting anything right now.'), findsOneWidget);
      expect(find.text('Kápsimo'), findsOneWidget);
      expect(find.text('PARTIES · 1'), findsOneWidget);
    });

    testWidgets('hosting nothing at all is one absence, not two', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository(), parties: _FakePartyRepository());
      await _scrollTo(tester, find.text('You have not hosted a party yet.'));

      expect(find.text('You have not hosted a party yet.'), findsOneWidget);

      // Two group headings over two empty notices would make an account that
      // has never hosted look like a screen that failed twice.
      expect(find.text('HOSTING'), findsNothing);
      expect(find.text('PAST'), findsNothing);
      expect(find.text('Ταράτσα στο Κουκάκι'), findsNothing);
    });

    testWidgets('a failed load says so rather than showing nothing', (tester) async {
      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        parties: _FakePartyRepository(fail: true),
      );
      await _scrollTo(tester, find.text('Your parties did not load'));

      // One request behind the list, so one error — a per-group failure would
      // be describing a fetch that does not happen.
      expect(find.text('Your parties did not load'), findsOneWidget);
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
      expect(find.text('HOSTING'), findsNothing);
      expect(find.textContaining('PARTIES · '), findsNothing);
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
      expect(find.textContaining('140 went'), findsOneWidget);
      // The year is printed because the party is not from this year.
      expect(find.textContaining('9 Aug 2025'), findsOneWidget);

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
      await _scrollTo(tester, find.text('No public parties yet.'));

      expect(find.text('No public parties yet.'), findsOneWidget);
    });
  });

  group('stat tiles', () {
    testWidgets('are the two the layout calls for, sourced from the row and the RPC', (tester) async {
      await _pumpProfile(tester, _FakeProfileRepository());

      // followerCount off the profiles row, partiesHosted off
      // get_profile_stats. Two tiles, two numbers.
      expect(find.text('FOLLOWERS'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('HOSTED'), findsOneWidget);
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
      expect(find.text('FOLLOWERS'), findsOneWidget);
      expect(find.text('HOSTED'), findsOneWidget);

      await _pumpProfile(
        tester,
        _FakeProfileRepository(),
        target: const OtherProfile('someone-else'),
      );

      // Nothing in this row is viewer-dependent any more. The tile that was —
      // "πάρτι φέτος", structurally zero for anyone but the owner because
      // get_profile_stats runs with invoker rights over an owner-scoped rsvps
      // policy — is gone, so the row's shape no longer encodes who is looking.
      expect(find.text('FOLLOWERS'), findsOneWidget);
      expect(find.text('HOSTED'), findsOneWidget);
    });
  });

  group('live follower count', () {
    const them = OtherProfile('someone-else');

    Future<_LiveSocialRepository> pumpLive(WidgetTester tester, _FollowServer server, {bool refuse = false}) async {
      final social = _LiveSocialRepository(server, refuse: refuse);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileScreen(
            target: them,
            repository: _LiveProfileRepository(server),
            social: social,
            parties: _FakePartyRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return social;
    }

    testWidgets('following moves their FOLLOWERS tile before the server answers', (tester) async {
      final server = _FollowServer();
      final social = await pumpLive(tester, server);
      expect(find.text('42'), findsOneWidget);

      social.inFlight = Completer<void>();
      await tester.tap(find.text('Follow'));
      await tester.pump();

      // Optimistic: the write has not landed and the tile has already moved.
      expect(server.followers, 42);
      expect(find.text('43'), findsOneWidget);

      social.inFlight!.complete();
      await tester.pumpAndSettle();

      // And the refetch the write announced agrees with it, rather than
      // snapping the tile back to a number read before the write.
      expect(server.followers, 43);
      expect(find.text('43'), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
    });

    testWidgets('unfollowing moves it back down', (tester) async {
      final server = _FollowServer();
      await pumpLive(tester, server);

      await tester.tap(find.text('Follow'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Following'));
      await tester.pumpAndSettle();

      expect(find.text('42'), findsOneWidget);
      expect(find.text('Follow'), findsOneWidget);
    });

    testWidgets('a refused follow puts the count and the button back', (tester) async {
      final server = _FollowServer();
      await pumpLive(tester, server, refuse: true);

      await tester.tap(find.text('Follow'));
      await tester.pumpAndSettle();

      expect(find.text('42'), findsOneWidget);
      expect(find.text('43'), findsNothing);
      expect(find.text('Follow'), findsOneWidget);
    });

    testWidgets('a follow made somewhere else reaches this profile without a refresh', (tester) async {
      final server = _FollowServer();
      await pumpLive(tester, server);

      // Another screen's button — a second copy of this profile, a feed card —
      // goes through the same repository method, which announces the write.
      await _LiveSocialRepository(server).follow('someone-else');
      await tester.pumpAndSettle();

      expect(find.text('43'), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
    });

    testWidgets('a follow of somebody else leaves this profile alone', (tester) async {
      final server = _FollowServer();
      final profiles = _LiveProfileRepository(server);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileScreen(
            target: them,
            repository: profiles,
            social: _LiveSocialRepository(server),
            parties: _FakePartyRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = profiles.fetches;

      await _LiveSocialRepository(_FollowServer()).follow('a-third-person');
      await tester.pumpAndSettle();

      expect(profiles.fetches, before);
      expect(find.text('Follow'), findsOneWidget);
    });
  });

  group('live hosting', () {
    testWidgets('hosting a party moves HOSTED and adds it to the list without a refresh', (tester) async {
      final profiles = _HostingProfiles();
      final parties = _HostingParties(profiles);
      await _pumpProfile(tester, profiles, parties: parties);
      expect(find.text('3'), findsOneWidget);

      // The host wizard's call, made from the Parties tab.
      await parties.createPartyWithInvites(party: {'title': 'Rooftop opening'});
      await tester.pumpAndSettle();

      expect(find.text('4'), findsOneWidget);
      expect(find.text('3'), findsNothing);
      await _scrollTo(tester, find.text('Rooftop opening'));
      expect(find.text('Rooftop opening'), findsOneWidget);
    });

    testWidgets('pulling the profile down refetches it', (tester) async {
      final profiles = _HostingProfiles();
      final parties = _HostingParties(profiles);
      await _pumpProfile(tester, profiles, parties: parties);

      // Changed on the server with no event at all — someone else's write.
      profiles.hosted = 9;
      await tester.fling(find.text('FOLLOWERS'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(find.text('9'), findsOneWidget);
    });
  });
}
