import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/party_repository.dart';
import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/data/social_repository.dart';
import 'package:myparty/models/hosted_parties.dart';
import 'package:myparty/models/party_list_item.dart';
import 'package:myparty/models/party_summary.dart';
import 'package:myparty/models/profile.dart';
import 'package:myparty/models/profile_stats.dart';
import 'package:myparty/ui/screens/profile_screen.dart';
import 'package:myparty/ui/widgets/follow_button.dart';
import 'package:myparty/ui/widgets/party_detail_sheet.dart';
import 'package:myparty/ui/widgets/user_link.dart';

const _me = 'me';
const _hostId = '11111111-1111-1111-1111-111111111111';
const _erasedId = '22222222-2222-2222-2222-222222222222';
const _erasedHandle = 'deleted_22222222222222222222222222222222';

/// Answers for whichever id the screen asks about, and resolves "no id" to the
/// signed-in user, as the real one does from the session.
class _FakeProfiles extends ProfileRepository {
  final List<String?> fetched = [];

  @override
  String? get currentUserId => _me;

  @override
  Future<Profile?> fetchProfile({String? userId}) async {
    final id = userId ?? _me;
    fetched.add(id);
    return Profile(
      id: id,
      username: id == _me ? 'nikos' : 'dj_eleni',
      followerCount: 4,
      followingCount: 2,
    );
  }

  @override
  Future<ProfileStats> fetchStats({String? userId}) async => ProfileStats.empty;

  @override
  String? avatarUrl(String? path) => null;
}

class _FakeSocial extends SocialRepository {
  @override
  Future<List<Profile>> fetchFollowing({String? userId}) async => const [];

  @override
  Future<bool> isFollowing(String userId) async => false;
}

class _FakeParties extends PartyRepository {
  @override
  String? get currentUserId => _me;

  @override
  Future<List<PartySummary>> fetchHostedParties({
    String? hostId,
    required PartyWindow window,
    bool publicOnly = false,
    int limit = 12,
  }) async =>
      const [];

  @override
  Future<HostedParties> fetchMyHostedParties() async => HostedParties.empty;

  @override
  Future<Map<String, String>> signedCoverUrls(List<PartySummary> parties, {int expiresIn = 3600}) async =>
      const {};
}

PartyListItem _item({
  required bool isPrivate,
  String hostId = _hostId,
  String hostUsername = 'dj_eleni',
}) {
  return PartyListItem(
    partyId: 'p1',
    title: 'Techno Monday',
    description: 'A description.',
    startsAt: DateTime.now().add(const Duration(hours: 5)),
    endsAt: null,
    area: 'Psyrri',
    coverPath: null,
    isPrivate: isPrivate,
    isSponsored: false,
    hostId: hostId,
    hostUsername: hostUsername,
    isLive: false,
    goingCount: isPrivate ? null : 3,
    interestedCount: isPrivate ? null : 9,
    myRsvp: null,
    isInvited: isPrivate,
    sortGroup: isPrivate ? 0 : 1,
    sortRank: 0,
  );
}

void main() {
  late _FakeProfiles profiles;

  setUp(() {
    profiles = _FakeProfiles();
    final previous = userProfileScreenBuilder;
    addTearDown(() => userProfileScreenBuilder = previous);
    // The real ProfileScreen, with fakes in place of the network.
    userProfileScreenBuilder = (target) => ProfileScreen(
          target: target,
          repository: profiles,
          social: _FakeSocial(),
          parties: _FakeParties(),
        );
  });

  /// A screen with a button that opens the sheet, so the test can see the
  /// sheet survive the trip to the profile and back.
  Future<void> openSheet(WidgetTester tester, PartyListItem item) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPartyDetailSheet(context, item, repository: _FakeParties()),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(PartyDetailSheet), findsOneWidget);
  }

  for (final isPrivate in [false, true]) {
    final variant = isPrivate ? 'private' : 'public';
    // The invitation is the "Invited by @host" badge now, not a byline clause.
    final byline = isPrivate ? 'Private · @dj_eleni' : 'Public · @dj_eleni';

    testWidgets('tapping the host on a $variant party sheet opens their profile, and back returns to the sheet',
        (tester) async {
      await openSheet(tester, _item(isPrivate: isPrivate));

      await tester.tap(find.text(byline));
      await tester.pumpAndSettle();

      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.text('@dj_eleni'), findsOneWidget);
      expect(profiles.fetched, contains(_hostId));
      // Somebody else's profile: the follow button is there.
      expect(find.byType(FollowButton), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.byType(ProfileScreen), findsNothing);
      expect(find.byType(PartyDetailSheet), findsOneWidget, reason: 'the sheet is still open underneath');
      expect(find.text('Techno Monday'), findsOneWidget);
    });
  }

  testWidgets('the byline answers a tap above its text, inside the 44px target', (tester) async {
    await openSheet(tester, _item(isPrivate: false));

    final top = tester.getRect(find.text('Public · @dj_eleni')).topLeft;

    // Well past the reach, on the title: nothing.
    await tester.tapAt(top + const Offset(8, -30));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileScreen), findsNothing);

    // 10px above the text's top edge: over the title, which takes no taps.
    await tester.tapAt(top + const Offset(8, -10));
    await tester.pumpAndSettle();

    expect(find.byType(ProfileScreen), findsOneWidget);
  });

  testWidgets('tapping yourself as host opens YOUR profile, not a stranger view of it', (tester) async {
    // The sheet widget itself, not showPartyDetailSheet: since Phase 39 that
    // sends a host to their dashboard instead (host_dashboard_test.dart). The
    // byline still has to do the right thing for whoever it does render for.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PartyDetailSheet(item: _item(isPrivate: false, hostId: _me, hostUsername: 'nikos')),
      ),
    ));

    await tester.tap(find.text('Public · @nikos'));
    await tester.pumpAndSettle();

    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(find.text('@nikos'), findsOneWidget);
    // Owner view: no follow button pointed at yourself, and the gear is there.
    expect(find.byType(FollowButton), findsNothing);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    // Still a pushed route, so back still returns to the sheet.
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets("an erased host's tombstone handle is not a link", (tester) async {
    await openSheet(tester, _item(isPrivate: false, hostId: _erasedId, hostUsername: _erasedHandle));

    await tester.tap(find.text('Public · @$_erasedHandle'));
    await tester.pumpAndSettle();

    expect(find.byType(ProfileScreen), findsNothing);
    expect(profiles.fetched, isEmpty);
  });

  test('only the exact tombstone shape counts as erased', () {
    expect(isErasedHandle(_erasedHandle), isTrue);
    expect(isErasedHandle('deleted_fan'), isFalse);
    expect(isErasedHandle('dj_eleni'), isFalse);
    expect(isErasedHandle(null), isFalse);
  });
}
