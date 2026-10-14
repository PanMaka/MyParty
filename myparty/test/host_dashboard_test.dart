import 'dart:async';
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

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
}) {
  return HostPartyStats(
    partyId: _partyId,
    title: 'Rooftop Night',
    description: 'Bring friends.',
    area: 'Psiri',
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
  _FakeRepo({HostPartyStats? stats, RsvpTimeline? timeline, this.statsGate})
      : stats = stats ?? _stats(),
        timeline = timeline ??
            RsvpTimeline(bucket: StatsBucket.day, points: [
              RsvpTimelinePoint(at: DateTime(2026, 10, 1), going: 1, interested: 3),
              RsvpTimelinePoint(at: DateTime(2026, 10, 2), going: 3, interested: 8),
            ]);

  HostPartyStats stats;
  RsvpTimeline timeline;

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
  Future<RsvpTimeline> fetchRsvpTimeline(String partyId, {StatsBucket? bucket}) async => timeline;

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

Widget _dashboard(_FakeRepo repo) => MaterialApp(
      home: HostDashboardScreen(
        partyId: _partyId,
        repository: repo,
        profiles: _FakeProfiles(),
        share: (text) async => _shared.add(text),
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
  setUp(_shared.clear);

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
    expect(find.byKey(const Key('tile-here-now')), findsNothing, reason: 'not live yet');
    expect(find.byType(LineChart), findsOneWidget);

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
    expect(find.text('COMING OVER TIME'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Coming · 2'), 200);
    expect(find.textContaining('Interested ·'), findsNothing);
  });

  testWidgets('a live party adds "Here now", captioned as what it is', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_dashboard(_FakeRepo(stats: _stats(isLive: true))));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('phase-live')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tile-here-now')), matching: find.text('3')), findsOneWidget);
    expect(find.text('said they’d come'), findsOneWidget);
  });

  testWidgets('no RSVPs yet: the empty state offers the share sheet', (tester) async {
    final repo = _FakeRepo(timeline: const RsvpTimeline(bucket: StatsBucket.hour, points: []));
    _tall(tester);
    await tester.pumpWidget(_dashboard(repo));
    await tester.pumpAndSettle();

    expect(find.text('No RSVPs yet — share your party'), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);

    await tester.tap(find.descendant(of: find.byKey(const Key('chart-empty')), matching: find.text('Share')));
    expect(_shared.single, contains('https://mypartycorp.com/p/$_partyId'));
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
    expect(find.text('Bring friends.'), findsOneWidget);
    // Privacy and invites are not part of an edit.
    expect(find.text('Who sees it?'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Rooftop Night'), 'Rooftop Night II');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(repo.edits.single.title, 'Rooftop Night II');
    expect(repo.edits.single.area, 'Psiri');
    expect(repo.edits.single.lat, 37.97);
    expect(repo.coverReplacements, isEmpty, reason: 'no new cover was picked');
    // Back on the dashboard, which refetched.
    expect(find.byType(HostWizardScreen), findsNothing);
    expect(repo.statsFetches, greaterThan(fetchesBefore));
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
}
