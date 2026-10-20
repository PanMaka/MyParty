import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

import 'package:myparty/data/invite_link_store.dart';
import 'package:myparty/data/party_host_channel.dart';
import 'package:myparty/data/party_repository.dart';
import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/models/host_party_stats.dart';
import 'package:myparty/models/map_party_pin.dart';
import 'package:myparty/models/party_list_item.dart';
import 'package:myparty/models/profile.dart';
import 'package:myparty/state/data_changes.dart';
import 'package:myparty/ui/screens/host_dashboard_screen.dart';
import 'package:myparty/ui/screens/host_wizard_screen.dart';
import 'package:myparty/ui/screens/invite_followers_screen.dart';
import 'package:myparty/ui/widgets/gender_mix_bar.dart';
import 'package:myparty/ui/widgets/invite_link_sheet.dart';
import 'package:myparty/ui/widgets/map_pin_sheet.dart';
import 'package:myparty/ui/widgets/party_detail_sheet.dart';
import 'package:myparty/ui/widgets/user_link.dart';

const _host = 'host-uuid';
const _partyId = 'party-1';

HostPartyStats _stats({
  bool isPrivate = false,
  String status = 'published',
  bool isLive = false,
  bool isOver = false,
  int going = 3,
  int interested = 8,
  GenderMix? goingGender,
  GenderMix? interestedGender,
}) {
  return HostPartyStats(
    partyId: _partyId,
    title: 'Rooftop Night',
    description: 'Bring friends.',
    area: 'Psiri',
    address: 'Αισχύλου 12, rooftop',
    startsAt: DateTime.now().add(const Duration(days: 2)),
    endsAt: null,
    coverPath: null,
    isPrivate: isPrivate,
    status: status,
    lat: 37.97,
    lng: 23.72,
    isLive: isLive,
    isOver: isOver,
    goingCount: going,
    interestedCount: interested,
    goingFollowers: 1,
    goingNonFollowers: going - 1,
    interestedFollowers: 2,
    interestedNonFollowers: interested - 2,
    goingGender: goingGender,
    interestedGender: interestedGender,
  );
}

PartyGuest _guest(String name, {bool going = false, bool follows = false}) => PartyGuest(
      userId: 'u-$name',
      username: name,
      avatarPath: null,
      going: going,
      followsHost: follows,
      createdAt: DateTime.utc(2026, 10, 1),
    );

class _FakeRepo extends PartyRepository {
  _FakeRepo({HostPartyStats? stats, this.statsGate, this.link}) : stats = stats ?? _stats();

  HostPartyStats stats;

  /// The party's active invite link as the server would describe it.
  InviteLinkStatus? link;
  int tokensMade = 0;
  final List<int?> linkMaxUses = [];
  int linksDisabled = 0;

  final List<List<String>> invitesSent = [];
  final List<String> removed = [];

  /// When set, stats wait for it: lets a test look at the loading state.
  final Completer<void>? statsGate;

  int statsFetches = 0;
  final List<bool> guestFetches = [];
  final List<String> cancelled = [];
  final List<PartyEdit> edits = [];
  final List<String> coverReplacements = [];

  final activity = StreamController<void>.broadcast();
  final status = StreamController<RealtimeSubscribeStatus>.broadcast();
  int topicJoins = 0;

  @override
  String? get currentUserId => _host;

  @override
  Future<HostPartyStats?> fetchHostStats(String partyId) async {
    statsFetches += 1;
    await statsGate?.future;
    return stats;
  }

  @override
  Future<InvitableFollowerPage> fetchInvitableFollowers(
    String partyId, {
    String? query,
    InvitableFollower? after,
    int limit = 50,
  }) async {
    final all = [
      const InvitableFollower(userId: 'u-dee', username: 'dee', avatarPath: null, alreadyInvited: false, rsvpStatus: null),
      const InvitableFollower(userId: 'u-eli', username: 'eli', avatarPath: null, alreadyInvited: true, rsvpStatus: null),
      const InvitableFollower(userId: 'u-fay', username: 'fay', avatarPath: null, alreadyInvited: false, rsvpStatus: 'going'),
    ];
    final q = query?.toLowerCase();
    return InvitableFollowerPage(
      followers: [for (final f in all) if (q == null || f.username.contains(q)) f],
      cursor: null,
    );
  }

  @override
  Future<int> writeInvites(String partyId, List<String> userIds) async {
    invitesSent.add(userIds);
    return userIds.length;
  }

  @override
  Future<PartyInviteePage> fetchInvitees(String partyId, {PartyInvitee? after, int limit = 30}) async {
    return PartyInviteePage(invitees: [
      PartyInvitee(
          userId: 'u-gus', username: 'gus', avatarPath: null, rsvpStatus: null, viaLink: true, createdAt: DateTime.utc(2026, 10, 2)),
      PartyInvitee(
          userId: 'u-ana', username: 'ana', avatarPath: null, rsvpStatus: 'going', viaLink: false, createdAt: DateTime.utc(2026, 10, 1)),
    ], cursor: null);
  }

  @override
  Future<void> writeRemoval(String partyId, String userId) async => removed.add(userId);

  @override
  Future<InviteLinkStatus?> fetchInviteLink(String partyId) async => link;

  @override
  Future<String> createInviteLink(String partyId, {int? maxUses}) async {
    tokensMade += 1;
    linkMaxUses.add(maxUses);
    link = InviteLinkStatus(createdAt: DateTime.utc(2026, 10, 16, 12, tokensMade), maxUses: maxUses, useCount: 0);
    return 'tok${tokensMade}_'.padRight(43, 'x');
  }

  @override
  Future<void> disableInviteLink(String partyId) async {
    linksDisabled += 1;
    link = null;
  }

  @override
  Future<PartyGuestPage> fetchGuests(String partyId, {required bool goingOnly, PartyGuest? after, int limit = 30}) async {
    guestFetches.add(goingOnly);
    final all = [
      _guest('ana', going: true, follows: true),
      _guest('bo', going: true),
      _guest('cy'),
    ];
    return PartyGuestPage(
      guests: goingOnly ? all.where((g) => g.going).toList() : all,
      cursor: null,
    );
  }

  @override
  PartyHostChannel subscribeHostTopic(String partyId) {
    topicJoins += 1;
    return PartyHostChannel(activity: activity.stream, status: status.stream, dispose: () async {});
  }

  @override
  Future<String?> signedCoverUrl(String? coverPath, {int expiresIn = 3600}) async => null;

  @override
  Future<void> writeCancel(String partyId) async => cancelled.add(partyId);

  @override
  Future<void> writePartyEdit(PartyEdit edit) async => edits.add(edit);

  @override
  Future<String> putReplacementCover(String partyId, Uint8List bytes) async {
    coverReplacements.add(partyId);
    return '$partyId/new';
  }

  final List<String> cleanups = [];

  @override
  Future<void> cleanUpCovers(String partyId) async => cleanups.add(partyId);
}

class _FakeProfiles extends ProfileRepository {
  @override
  String? get currentUserId => _host;

  @override
  Future<Profile?> fetchProfile({String? userId}) async =>
      const Profile(id: _host, username: 'host_user', followerCount: 0, followingCount: 0);

  @override
  String? avatarUrl(String? path) => null;
}

final List<String> _shared = [];

/// A phone-width, very tall surface, so the whole dashboard is built without
/// scrolling (ListView builds lazily, and 800x600 stops above the tiles).
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _dashboard(_FakeRepo repo, {InviteLinkStore? store}) => MaterialApp(
      home: HostDashboardScreen(
        partyId: _partyId,
        repository: repo,
        profiles: _FakeProfiles(),
        share: (text) async => _shared.add(text),
        linkStore: store ?? InviteLinkStore(),
      ),
    );

MapPartyPin _pin({required String hostId}) => MapPartyPin(
      id: _partyId,
      lat: 37.97,
      lng: 23.72,
      title: 'Rooftop Night',
      isPrivate: false,
      goingCount: 3,
      interestedCount: 8,
      startsAt: DateTime.now().add(const Duration(days: 2)),
      hostId: hostId,
      hostUsername: 'someone',
    );

PartyListItem _item({required String hostId}) => PartyListItem(
      partyId: _partyId,
      title: 'Rooftop Night',
      description: null,
      startsAt: DateTime.now().add(const Duration(days: 2)),
      endsAt: null,
      area: null,
      coverPath: null,
      isPrivate: false,
      isSponsored: false,
      hostId: hostId,
      hostUsername: 'someone',
      isLive: false,
      goingCount: 3,
      interestedCount: 8,
      myRsvp: null,
      isInvited: false,
      sortGroup: 1,
      sortRank: 0,
    );

/// A screen whose button runs [open], so a test can see where a door leads.
Future<void> _tapDoor(WidgetTester tester, void Function(BuildContext) open) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(onPressed: () => open(context), child: const Text('open')),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    _shared.clear();
    // InviteLinkStore's device storage, empty for every test.
    SharedPreferences.setMockInitialValues({});
  });

  group('routing: the host gets the dashboard, everyone else the sheet', () {
    testWidgets('a map pin / search hit / MY PARTIES row of your own party', (tester) async {
      final repo = _FakeRepo();
      await _tapDoor(tester, (c) => showMapPinSheet(c, _pin(hostId: _host), repository: repo));

      expect(find.byType(HostDashboardScreen), findsOneWidget);
      expect(find.byType(MapPinSheet), findsNothing);
    });

    testWidgets('somebody else\'s pin still opens the attendee sheet', (tester) async {
      final repo = _FakeRepo();
      await _tapDoor(tester, (c) => showMapPinSheet(c, _pin(hostId: 'someone-else'), repository: repo));

      expect(find.byType(MapPinSheet), findsOneWidget);
      expect(find.byType(HostDashboardScreen), findsNothing);
    });

    testWidgets('an ALL PARTIES card or a party link of your own party', (tester) async {
      final repo = _FakeRepo();
      await _tapDoor(tester, (c) => showPartyDetailSheet(c, _item(hostId: _host), repository: repo));

      expect(find.byType(HostDashboardScreen), findsOneWidget);
      expect(find.byType(PartyDetailSheet), findsNothing);
    });

    testWidgets('and somebody else\'s still opens the detail sheet', (tester) async {
      final repo = _FakeRepo();
      await _tapDoor(tester, (c) => showPartyDetailSheet(c, _item(hostId: 'someone-else'), repository: repo));

      expect(find.byType(PartyDetailSheet), findsOneWidget);
    });
  });

  testWidgets('a loading dashboard shows skeletons, not a spinner over nothing', (tester) async {
    final gate = Completer<void>();
    _tall(tester);
    await tester.pumpWidget(_dashboard(_FakeRepo(statsGate: gate)));
    await tester.pump();

    expect(find.byKey(const Key('dashboard-skeleton')), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dashboard-skeleton')), findsNothing);
    expect(find.text('Rooftop Night'), findsOneWidget);
  });

  testWidgets('a public party: Going and Interested tiles, the chart, both guest tabs', (tester) async {
    final repo = _FakeRepo();
    _tall(tester);
    await tester.pumpWidget(_dashboard(repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('phase-upcoming')), findsOneWidget);
    expect(find.text('PUBLIC'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tile-going')), matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tile-interested')), matching: find.text('8')), findsOneWidget);
    expect(find.byKey(const Key('tile-coming')), findsNothing);
    expect(find.text('RSVPS OVER TIME'), findsNothing, reason: 'the chart was removed in Phase 40');

    // Going tab first: the two going guests, no GOING badge (it is the tab).
    await tester.scrollUntilVisible(find.text('@ana'), 200);
    expect(find.text('@ana'), findsOneWidget);
    expect(find.text('@bo'), findsOneWidget);
    expect(find.text('@cy'), findsNothing);
    expect(find.text('FOLLOWS YOU'), findsOneWidget);

    // Interested lists everyone, going included, and badges the going ones.
    await tester.tap(find.text('Interested · 8'));
    await tester.pumpAndSettle();
    expect(find.text('@cy'), findsOneWidget);
    expect(find.descendant(of: find.byType(UserLink), matching: find.text('GOING')), findsNWidgets(2));
    expect(repo.guestFetches, containsAllInOrder([true, false]));
  });

  testWidgets('a private party: one Coming tile, one Coming tab, no Interested anywhere', (tester) async {
    final repo = _FakeRepo(stats: _stats(isPrivate: true, going: 2, interested: 2));
    _tall(tester);
    await tester.pumpWidget(_dashboard(repo));
    await tester.pumpAndSettle();

    expect(find.text('PRIVATE'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tile-coming')), matching: find.text('2')), findsOneWidget);
    expect(find.byKey(const Key('tile-going')), findsNothing);
    expect(find.byKey(const Key('tile-interested')), findsNothing);
    expect(find.text('COMING OVER TIME'), findsNothing);
    await tester.scrollUntilVisible(find.text('Coming · 2'), 200);
    expect(find.textContaining('Interested ·'), findsNothing);
    expect(find.byKey(const Key('tab-invited')), findsOneWidget);
  });

  testWidgets('a live party shows its phase, and no "Here now" tile any more', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_dashboard(_FakeRepo(stats: _stats(isLive: true))));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('phase-live')), findsOneWidget);
    expect(find.byKey(const Key('tile-here-now')), findsNothing);
    expect(find.text('Here now'), findsNothing);
  });

  testWidgets('cancelling asks first; "Keep it" writes nothing, confirming cancels', (tester) async {
    final repo = _FakeRepo();
    _tall(tester);
    await tester.pumpWidget(_dashboard(repo));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const Key('dashboard-cancel')), 300);
    await tester.tap(find.byKey(const Key('dashboard-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Cancel this party?'), findsOneWidget);
    expect(find.textContaining('not notified'), findsOneWidget);

    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(repo.cancelled, isEmpty);

    await tester.tap(find.byKey(const Key('dashboard-cancel')));
    await tester.pumpAndSettle();
    repo.stats = _stats(status: 'cancelled');
    await tester.tap(find.byKey(const Key('confirm-cancel-party')));
    await tester.pumpAndSettle();

    expect(repo.cancelled, [_partyId]);
    // PartyCancelled reaches the dashboard itself, which refetches and shows
    // the new state: no more Cancel, Edit or Share.
    expect(find.byKey(const Key('phase-cancelled')), findsOneWidget);
    expect(find.byKey(const Key('dashboard-cancel')), findsNothing);
    final edit = tester.widget<OutlinedButton>(find.byKey(const Key('dashboard-edit')));
    expect(edit.onPressed, isNull);
  });

  testWidgets('an ended party offers no Cancel', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_dashboard(_FakeRepo(stats: _stats(isOver: true))));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('phase-ended')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('dashboard-view-as-guest')), 300);
    expect(find.byKey(const Key('dashboard-cancel')), findsNothing);
  });

  testWidgets('View as guest opens the attendee sheet in preview, with RSVP disabled', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_dashboard(_FakeRepo()));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const Key('dashboard-view-as-guest')), 300);
    await tester.tap(find.byKey(const Key('dashboard-view-as-guest')));
    await tester.pumpAndSettle();

    expect(find.byType(MapPinSheet), findsOneWidget);
    expect(find.byKey(const Key('guest-preview-banner')), findsOneWidget);
    expect(find.text('@host_user'), findsOneWidget);
    final going = tester.widget<ElevatedButton>(
      find.ancestor(of: find.text('Going'), matching: find.byType(ElevatedButton)),
    );
    expect(going.onPressed, isNull);
  });

  testWidgets('Edit opens the create form prefilled and saves through update_party', (tester) async {
    final repo = _FakeRepo();
    _tall(tester);
    await tester.pumpWidget(_dashboard(repo));
    await tester.pumpAndSettle();
    final fetchesBefore = repo.statsFetches;

    await tester.scrollUntilVisible(find.byKey(const Key('dashboard-edit')), 300);
    await tester.tap(find.byKey(const Key('dashboard-edit')));
    await tester.pumpAndSettle();

    expect(find.byType(HostWizardScreen), findsOneWidget);
    expect(find.text('EDIT PARTY'), findsOneWidget);
    expect(find.text('Rooftop Night'), findsOneWidget);
    expect(find.text('Psiri'), findsOneWidget);
    expect(find.text('Αισχύλου 12, rooftop'), findsOneWidget, reason: 'the address is its own field since Phase 42');
    expect(find.text('Bring friends.'), findsOneWidget);
    // Privacy and invites are not part of an edit.
    expect(find.text('Who sees it?'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Rooftop Night'), 'Rooftop Night II');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(repo.edits.single.title, 'Rooftop Night II');
    expect(repo.edits.single.area, 'Psiri');
    expect(repo.edits.single.address, 'Αισχύλου 12, rooftop',
        reason: 'update_party is a full replacement: an address not sent back would be wiped');
    expect(repo.edits.single.description, 'Bring friends.');
    expect(repo.edits.single.lat, 37.97);
    expect(repo.coverReplacements, isEmpty, reason: 'no new cover was picked');
    // Back on the dashboard, which refetched.
    expect(find.byType(HostWizardScreen), findsNothing);
    expect(repo.statsFetches, greaterThan(fetchesBefore));
  });

  group('Invite people', () {
    testWidgets('followers: locked rows cannot be picked, the rest are sent', (tester) async {
      _tall(tester);
      final repo = _FakeRepo();
      await tester.pumpWidget(_dashboard(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('dashboard-invite')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invite-followers')));
      await tester.pumpAndSettle();

      expect(find.byType(InviteFollowersScreen), findsOneWidget);
      expect(find.text('@dee'), findsOneWidget);
      expect(find.text('Invited'), findsOneWidget, reason: 'eli is already invited');
      expect(find.text('Going'), findsOneWidget, reason: 'fay already answered');
      expect(find.byType(Checkbox), findsOneWidget, reason: 'only dee is selectable');

      final send = tester.widget<ElevatedButton>(find.byKey(const Key('send-invites')));
      expect(send.onPressed, isNull, reason: 'nothing selected yet');

      await tester.tap(find.byKey(const Key('follower-u-eli')));
      await tester.tap(find.byKey(const Key('follower-u-dee')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-invites')));
      await tester.pumpAndSettle();

      expect(repo.invitesSent, [
        ['u-dee'],
      ]);
      expect(find.byType(InviteFollowersScreen), findsNothing);
      expect(find.text('Invited 1 person.'), findsOneWidget);
    });

    testWidgets('search narrows the list on the server', (tester) async {
      _tall(tester);
      await tester.pumpWidget(MaterialApp(
        home: InviteFollowersScreen(partyId: _partyId, isPrivate: false, repository: _FakeRepo(), profiles: _FakeProfiles()),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('invite-search')), 'fa');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('@fay'), findsOneWidget);
      expect(find.text('@dee'), findsNothing);
    });

    testWidgets('a public party offers its ordinary link, not an invite link', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_dashboard(_FakeRepo()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('dashboard-invite')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invite-with-link')), findsNothing);
      await tester.tap(find.byKey(const Key('share-party-link')));
      await tester.pumpAndSettle();
      expect(_shared.single, contains('https://mypartycorp.com/p/$_partyId'));
    });

    testWidgets('a private party: create a link with a max-uses limit, then copy and share it', (tester) async {
      _tall(tester);
      final repo = _FakeRepo(stats: _stats(isPrivate: true, going: 1, interested: 1));
      await tester.pumpWidget(_dashboard(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('dashboard-invite')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invite-with-link')));
      await tester.pumpAndSettle();

      expect(find.byType(InviteLinkSheet), findsOneWidget);
      await tester.tap(find.byKey(const Key('max-uses-25')));
      await tester.tap(find.byKey(const Key('create-link')));
      await tester.pumpAndSettle();

      expect(repo.linkMaxUses, [25]);
      final shown = tester.widget<Text>(find.byKey(const Key('invite-link-text'))).data!;
      expect(shown, startsWith('https://mypartycorp.com/i#tok1_'), reason: 'the token rides in the fragment');
      expect(find.text('0 of 25 joined'), findsOneWidget);

      await tester.tap(find.byKey(const Key('share-link')));
      await tester.pump();
      expect(_shared.single, contains(shown));
      expect(_shared.single, isNot(contains('Rooftop Night')), reason: 'a private party is shared without its title');
    });

    testWidgets('the same link on another device cannot be shown, and says what a new one costs', (tester) async {
      _tall(tester);
      // The server has an active link; this device's storage has no token for it.
      final repo = _FakeRepo(
        stats: _stats(isPrivate: true, going: 1, interested: 1),
        link: InviteLinkStatus(createdAt: DateTime.utc(2026, 10, 1), maxUses: null, useCount: 4),
      );
      await tester.pumpWidget(_dashboard(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('dashboard-invite')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invite-with-link')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('link-other-device')), findsOneWidget);
      expect(find.textContaining('turns the old one off'), findsOneWidget);
      expect(find.byKey(const Key('copy-link')), findsNothing);
      expect(find.text('4 joined'), findsOneWidget);

      await tester.tap(find.byKey(const Key('regenerate-link')));
      await tester.pumpAndSettle();
      expect(find.textContaining('stops working straight away'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-link-action')));
      await tester.pumpAndSettle();

      expect(repo.tokensMade, 1);
      expect(find.byKey(const Key('copy-link')), findsOneWidget, reason: 'this device holds the new one');
    });

    testWidgets('a token saved on this device is offered again after reopening', (tester) async {
      _tall(tester);
      final store = InviteLinkStore();
      final created = DateTime.utc(2026, 10, 3);
      await store.save(_partyId, 'saved_'.padRight(43, 'y'), created);
      final repo = _FakeRepo(
        stats: _stats(isPrivate: true, going: 1, interested: 1),
        link: InviteLinkStatus(createdAt: created, maxUses: 10, useCount: 10),
      );
      await tester.pumpWidget(_dashboard(repo, store: store));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('dashboard-invite')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invite-with-link')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('copy-link')), findsOneWidget);
      expect(find.textContaining('Used up'), findsOneWidget);

      await tester.tap(find.byKey(const Key('disable-link')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-link-action')));
      await tester.pumpAndSettle();

      expect(repo.linksDisabled, 1);
      expect(await store.tokenFor(_partyId, created), isNull, reason: 'a turned-off link is forgotten here too');
      expect(find.byKey(const Key('create-link')), findsOneWidget);
    });

    test('a stored token is trusted only for the link it was made for', () async {
      final store = InviteLinkStore();
      await store.save(_partyId, 'old_'.padRight(43, 'z'), DateTime.utc(2026, 10, 1));
      expect(await store.tokenFor(_partyId, DateTime.utc(2026, 10, 2)), isNull,
          reason: 'regenerated elsewhere: offering this would share a dead link');
    });
  });

  group('Removing a guest', () {
    testWidgets('the Invited tab lists link guests who never answered, and Remove asks first', (tester) async {
      _tall(tester);
      final repo = _FakeRepo(stats: _stats(isPrivate: true, going: 1, interested: 1));
      await tester.pumpWidget(_dashboard(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('tab-invited')));
      await tester.pumpAndSettle();
      expect(find.text('@gus'), findsOneWidget);
      expect(find.text('VIA LINK'), findsOneWidget);
      expect(find.text('NO ANSWER'), findsOneWidget);
      expect(find.descendant(of: find.byType(UserLink), matching: find.text('COMING')), findsOneWidget,
          reason: 'a private party says Coming, not Going');

      await tester.tap(find.byKey(const Key('remove-u-gus')));
      await tester.pumpAndSettle();
      expect(find.text('Remove @gus?'), findsOneWidget);
      expect(find.textContaining('won’t let them back in'), findsOneWidget);

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(repo.removed, isEmpty);

      final before = repo.statsFetches;
      await tester.tap(find.byKey(const Key('remove-u-gus')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-remove-guest')));
      await tester.pumpAndSettle();

      expect(repo.removed, ['u-gus']);
      expect(find.text('Removed @gus.'), findsOneWidget);
      expect(repo.statsFetches, greaterThan(before), reason: 'PartyGuestsChanged refreshes the counts');
    });

    testWidgets('removing from a public party says the party stays visible to them', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_dashboard(_FakeRepo()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('remove-u-ana')));
      await tester.pumpAndSettle();
      expect(find.textContaining('they can still see it'), findsOneWidget);
    });

    testWidgets('a cancelled party offers neither Remove nor Invite people', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_dashboard(_FakeRepo(stats: _stats(status: 'cancelled'))));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('remove-u-ana')), findsNothing);
      expect(find.byKey(const Key('dashboard-invite')), findsNothing);
    });
  });

  test('a replaced cover is announced and asks for cleanup of the old one', () async {
    final repo = _FakeRepo();
    final heard = <String>[];
    final sub = dataChanges.stream.listen((c) {
      if (c is PartyCoverChanged) heard.add(c.partyId);
    });
    addTearDown(sub.cancel);

    await repo.replaceCover(_partyId, Uint8List.fromList([0xFF, 0xD8, 0xFF]));
    await Future<void>.delayed(Duration.zero);

    expect(repo.coverReplacements, [_partyId]);
    expect(repo.cleanups, [_partyId], reason: 'the primary cleanup path; party-cover-sweep is the net under it');
    expect(heard, [_partyId]);
  });

  testWidgets('someone else\'s RSVP on the host topic refetches, after a short settle', (tester) async {
    final repo = _FakeRepo();
    _tall(tester);
    await tester.pumpWidget(_dashboard(repo));
    await tester.pumpAndSettle();
    expect(repo.topicJoins, 1);
    final before = repo.statsFetches;

    repo.stats = _stats(going: 4, interested: 9);
    repo.activity
      ..add(null)
      ..add(null);
    await tester.pump();
    expect(repo.statsFetches, before, reason: 'a burst settles before it refetches');

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(repo.statsFetches, before + 1, reason: 'one refetch for the burst');
    expect(find.descendant(of: find.byKey(const Key('tile-going')), matching: find.text('4')), findsOneWidget);
  });
  group('Gender mix', () {
    Finder bar(String label) => find.ancestor(of: find.text(label), matching: find.byType(GenderMixBar));

    testWidgets('a public party: a Going and an Interested bar, each with its own counts', (tester) async {
      final repo = _FakeRepo(
        stats: _stats(
          going: 5,
          interested: 8,
          goingGender: const GenderMix(male: 1, female: 2, nonBinary: 1, unspecified: 1),
          interestedGender: const GenderMix(male: 2, female: 2, nonBinary: 1, unspecified: 3),
        ),
      );
      _tall(tester);
      await tester.pumpWidget(_dashboard(repo));
      await tester.pumpAndSettle();

      expect(find.text('GENDER MIX'), findsOneWidget);
      expect(find.byType(GenderMixBar), findsNWidgets(2));
      final going = find.byWidgetPredicate((w) => w is GenderMixBar && w.label == 'Going');
      final interested = find.byWidgetPredicate((w) => w is GenderMixBar && w.label == 'Interested');
      expect(find.descendant(of: going, matching: find.text('Women 2 · 40%')), findsOneWidget);
      expect(find.descendant(of: going, matching: find.text('5 guests')), findsOneWidget);
      expect(find.descendant(of: interested, matching: find.text('Not specified 3 · 38%')), findsOneWidget);
      expect(find.descendant(of: interested, matching: find.text('8 guests')), findsOneWidget);
    });

    testWidgets('a group the server withheld says "Not enough guests yet"; the other still shows', (tester) async {
      final repo = _FakeRepo(
        stats: _stats(
          going: 2,
          interested: 4,
          interestedGender: const GenderMix(male: 1, female: 1, nonBinary: 0, unspecified: 2),
        ),
      );
      _tall(tester);
      await tester.pumpWidget(_dashboard(repo));
      await tester.pumpAndSettle();

      expect(find.descendant(of: bar('Going'), matching: find.text(GenderMixBar.notEnough)), findsOneWidget);
      expect(find.descendant(of: bar('Going'), matching: find.textContaining('Men')), findsNothing);
      expect(find.descendant(of: bar('Interested'), matching: find.text('Men 1 · 25%')), findsOneWidget);
    });

    testWidgets('a private party: one Coming bar, no Interested', (tester) async {
      final repo = _FakeRepo(
        stats: _stats(
          isPrivate: true,
          going: 3,
          interested: 3,
          goingGender: const GenderMix(male: 1, female: 1, nonBinary: 1, unspecified: 0),
          interestedGender: const GenderMix(male: 1, female: 1, nonBinary: 1, unspecified: 0),
        ),
      );
      _tall(tester);
      await tester.pumpWidget(_dashboard(repo));
      await tester.pumpAndSettle();

      expect(find.byType(GenderMixBar), findsOneWidget);
      expect(find.descendant(of: bar('Coming'), matching: find.text('Non-binary 1 · 33%')), findsOneWidget);
    });

    testWidgets('it moves with an RSVP on the host topic, like the other stats', (tester) async {
      final repo = _FakeRepo(stats: _stats(going: 2));
      _tall(tester);
      await tester.pumpWidget(_dashboard(repo));
      await tester.pumpAndSettle();
      expect(find.descendant(of: bar('Going'), matching: find.text(GenderMixBar.notEnough)), findsOneWidget);

      repo.stats = _stats(
        going: 3,
        goingGender: const GenderMix(male: 0, female: 2, nonBinary: 0, unspecified: 1),
      );
      repo.activity.add(null);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(find.descendant(of: bar('Going'), matching: find.text('Women 2 · 67%')), findsOneWidget);
      expect(find.text(GenderMixBar.notEnough), findsOneWidget, reason: 'only Interested (null here) still withholds');
    });
  });
}
