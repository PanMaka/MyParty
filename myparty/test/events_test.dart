import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:myparty/data/party_repository.dart';
import 'package:myparty/models/party_list_item.dart';
import 'package:myparty/models/rsvp_party.dart';
import 'package:myparty/state/mp_store.dart';
import 'package:myparty/state/rsvp_changes.dart';
import 'package:myparty/ui/screens/events_screen.dart';
import 'package:myparty/ui/widgets/party_card.dart';
import 'package:myparty/ui/widgets/party_detail_sheet.dart';

/// Answers [PartyRepository.fetchMyRsvps] from a list instead of the network.
///
/// Possible only because `PartyRepository` resolves its Supabase client
/// lazily — no client is ever constructed here, the same trick `map_test.dart`
/// relies on.
class _FakePartyRepository extends PartyRepository {
  _FakePartyRepository(
    this.rsvps, {
    this.fail = false,
    this.pages = const {},
    this.listFails = false,
  });

  final List<RsvpParty> rsvps;
  final bool fail;

  /// One canned page per sort, so a test can assert that changing the sort
  /// REFETCHES rather than reorders what is already loaded. Keyed by sort
  /// because that is the whole contract under test: the order is the server's
  /// answer, not a local `..sort()`.
  final Map<PartySort, List<PartyListItem>> pages;
  final bool listFails;

  /// Every sort the screen asked for, in order. The assertion that the sort
  /// reached the server at all lives on this.
  final List<PartySort> sortsRequested = [];

  /// How many times MY PARTIES was (re)loaded.
  int rsvpFetches = 0;

  @override
  Future<List<RsvpParty>> fetchMyRsvps() async {
    rsvpFetches++;
    if (fail) throw Exception('nope');
    return rsvps;
  }

  @override
  Future<PartyListPage> fetchPartiesList({
    PartySort sort = PartySort.soonest,
    int limit = 30,
    PartyListCursor? cursor,
  }) async {
    sortsRequested.add(sort);
    if (listFails) throw Exception('nope');
    // Always a short page, so the screen treats it as the end of the list and
    // does not page forever against a fake that would happily repeat itself.
    return PartyListPage(items: pages[sort] ?? const [], cursor: null);
  }

  @override
  Future<Map<String, String>> signedListCoverUrls(
    List<PartyListItem> items, {
    int expiresIn = 3600,
  }) async =>
      {};

  final List<({String partyId, MpRsvp status, MpRsvp? current})> rsvpWrites = [];

  @override
  Future<void> setRsvp({
    required String partyId,
    required MpRsvp status,
    required MpRsvp? current,
  }) async {
    rsvpWrites.add((partyId: partyId, status: status, current: current));
  }
}

/// A row of the ALL PARTIES list.
///
/// [interested] and [going] default to NON-null, and a PRIVATE item is built
/// with both null -- which is what the server actually sends for a private row
/// (20260825090051). Building a private fixture with numbers would let a card
/// that forgot to hide them pass.
PartyListItem _item({
  required String id,
  required String title,
  bool isPrivate = false,
  bool isLive = false,
  DateTime? startsAt,
  int? interested = 12,
  int? going = 4,
  MpRsvp? myRsvp,
  String host = 'someone',
  String? area = 'Psyrri',
  bool isInvited = false,
  int sortGroup = 1,
  int sortRank = 0,
}) {
  return PartyListItem(
    partyId: id,
    title: title,
    description: 'A description.',
    startsAt: startsAt ?? DateTime.now().add(const Duration(hours: 5)),
    endsAt: null,
    area: area,
    coverPath: null,
    isPrivate: isPrivate,
    isSponsored: false,
    hostId: '11111111-1111-1111-1111-111111111111',
    hostUsername: host,
    isLive: isLive,
    goingCount: isPrivate ? null : going,
    interestedCount: isPrivate ? null : interested,
    myRsvp: myRsvp,
    isInvited: isInvited,
    sortGroup: isPrivate ? 0 : sortGroup,
    sortRank: sortRank,
  );
}

RsvpParty _rsvp({
  required String title,
  required DateTime startsAt,
  bool isPrivate = false,
  String status = 'going',
  int going = 4,
  int interested = 0,
}) {
  return RsvpParty(
    partyId: '00000000-0000-0000-0000-00000000000${title.length % 10}',
    title: title,
    startsAt: startsAt,
    isPrivate: isPrivate,
    rsvpStatus: status,
    goingCount: going,
    interestedCount: interested,
  );
}

/// One PartyCard on its own.
///
/// No MpStore any more: the card is handed an immutable row and reports taps
/// through [onRsvp], so there is no shared mutable state left for it to read.
Widget _card(PartyListItem item, {void Function(MpRsvp)? onRsvp}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: PartyCard(item: item, onRsvp: onRsvp ?? (_) {}),
      ),
    ),
  );
}

Widget _host(PartyRepository repository, {DateTime Function()? clock}) {
  return ChangeNotifierProvider(
    create: (_) => MpStore(),
    child: MaterialApp(
      home: EventsScreen(repository: repository, clock: clock ?? DateTime.now),
    ),
  );
}

void main() {
  // The parties tab was the last screen still shipping Greek chrome. These
  // assert the strings themselves rather than a widget count, because the
  // regression being guarded against is a translation getting reverted, or a
  // newly added string arriving in the wrong language — neither of which
  // changes the widget tree's shape.
  group('the parties tab speaks English', () {
    testWidgets('the header is the wordmark, not a title', (tester) async {
      await tester.pumpWidget(_host(_FakePartyRepository(const [])));
      await tester.pumpAndSettle();

      final logo = tester.widget<Image>(
        find.descendant(of: find.byType(EventsScreen), matching: find.byType(Image)).first,
      );
      expect((logo.image as AssetImage).assetName, 'assets/images/content.png');

      // Swapping a Text for an Image must not cost the heading its accessible
      // name — TalkBack read the old title out.
      expect(find.bySemanticsLabel('MyParty'), findsOneWidget);
    });

    testWidgets('the segmented control and section header are translated', (tester) async {
      await tester.pumpWidget(_host(_FakePartyRepository(const [])));
      await tester.pumpAndSettle();

      expect(find.text('MY PARTIES'), findsOneWidget);
      expect(find.text('ALL PARTIES'), findsWidgets);
      expect(find.text('ΔΙΚΑ ΜΟΥ'), findsNothing);
    });

    testWidgets('the host button is translated and no longer the loudest thing', (tester) async {
      await tester.pumpWidget(_host(_FakePartyRepository(const [])));
      await tester.pumpAndSettle();

      expect(find.text('Host a party'), findsOneWidget);

      // Discreet means shrink-wrapped, not full-bleed: the button must be
      // far narrower than the party cards it sits above. The gradient card it
      // replaced spanned the whole viewport minus 28px.
      final button = tester.getSize(find.ancestor(
        of: find.text('Host a party'),
        matching: find.byType(Container),
      ).first);
      final screen = tester.getSize(find.byType(EventsScreen));
      expect(button.width, lessThan(screen.width * 0.4));
    });

    testWidgets('the party list renders real rows in English', (tester) async {
      // Was "the mock party list": it asserted over every field of every
      // mpParties entry, which was the right test while the data was a const
      // map shipped in the binary. There is no such data any more -- the rows
      // come from get_parties_list -- so what is left to assert here is the
      // CHROME, which is still ours to get wrong.
      await tester.pumpWidget(_host(_FakePartyRepository(const [], pages: {
        PartySort.soonest: [
          _item(id: 'p1', title: 'Techno Monday', host: 'vinyl_room'),
          _item(id: 'p2', title: 'Rooftop in Koukaki', isPrivate: true),
        ],
      })));
      await tester.pumpAndSettle();

      expect(find.byType(PartyCard), findsNWidgets(2));
      expect(find.text('Techno Monday'), findsOneWidget);
      expect(find.text('@vinyl_room · Psyrri'), findsOneWidget);

      // The hype bar went with mpParties -- a percentage with no column behind
      // it. What stands in its place is the real counter it was a picture of.
      expect(find.text('HYPE NOW'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(find.text('12 interested'), findsOneWidget);

      final greek = RegExp(r'[Ͱ-Ͽἀ-῿]');
      for (final w in tester.widgetList<Text>(find.byType(Text))) {
        final t = w.data;
        if (t == null) continue;
        expect(greek.hasMatch(t), isFalse, reason: '"$t" is still Greek');
      }
    });

    testWidgets('rsvp sections, badges and stamps are translated', (tester) async {
      // A fixed evening, not the real clock: TONIGHT ends at local midnight,
      // so "now + 2h" read off DateTime.now() lands in THIS WEEK after 22:00.
      // In the future so nothing comparing against the real clock sees these
      // parties as past.
      final now = DateTime(2030, 6, 14, 20);
      await tester.pumpWidget(_host(_FakePartyRepository([
        _rsvp(title: 'Tonight one', startsAt: now.add(const Duration(hours: 2))),
        // 'going', not 'interested': a private party cannot hold an
        // interested row at all since 20260825090050, so an 'interested'
        // fixture here would be describing a state the database refuses.
        _rsvp(
          title: 'Later this week',
          startsAt: now.add(const Duration(days: 3)),
          isPrivate: true,
          status: 'going',
          going: 5,
          interested: 0,
        ),
        _rsvp(title: 'Much later', startsAt: now.add(const Duration(days: 20))),
      ]), clock: () => now));
      await tester.pumpAndSettle();

      await tester.tap(find.text('MY PARTIES'));
      await tester.pumpAndSettle();

      expect(find.text('TONIGHT'), findsOneWidget);
      expect(find.text('THIS WEEK'), findsOneWidget);
      expect(find.text('LATER'), findsOneWidget);

      // The two public rows say GOING; the private one says COMING, matching
      // the single button that wrote it.
      expect(find.text('GOING'), findsNWidgets(2));
      expect(find.text('COMING'), findsOneWidget);
      expect(find.text('INTERESTED'), findsNothing);

      // PrivacyBadge is shared with six untranslated surfaces, so this screen
      // opts in per call site rather than flipping the widget's default.
      expect(find.text('PRIVATE'), findsOneWidget);
      expect(find.text('PUBLIC'), findsNWidgets(2));

      // Attendance on the two PUBLIC rows only. The private row carries a
      // going_count of 5 in the fixture and still prints nothing.
      expect(find.text('4 going'), findsNWidgets(2));
      expect(find.text('5 going'), findsNothing);
      expect(find.textContaining('interested'), findsNothing);

      // formatPartyStartEn, not its Greek twin.
      expect(find.textContaining('Tonight '), findsWidgets);
      expect(find.textContaining('Απόψε'), findsNothing);
    });

    testWidgets('late at night, "two hours from now" is tomorrow, not tonight', (tester) async {
      // The case the real clock used to hit after 22:00. TONIGHT ends at local
      // midnight, so at 23:00 a party at 23:30 is tonight and one at 01:00 is
      // not -- and its label must not call it "Tonight" either.
      final now = DateTime(2030, 6, 14, 23);
      await tester.pumpWidget(_host(_FakePartyRepository([
        _rsvp(title: 'Before midnight', startsAt: now.add(const Duration(minutes: 30))),
        _rsvp(title: 'After midnight', startsAt: now.add(const Duration(hours: 2))),
      ]), clock: () => now));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MY PARTIES'));
      await tester.pumpAndSettle();

      expect(find.text('TONIGHT'), findsOneWidget);
      expect(find.text('THIS WEEK'), findsOneWidget);
      expect(find.text('Tonight 23:30'), findsOneWidget);
      expect(find.text('Sat 15 Jun, 01:00'), findsOneWidget);
    });

    testWidgets('the empty state is translated', (tester) async {
      await tester.pumpWidget(_host(_FakePartyRepository(const [])));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MY PARTIES'));
      await tester.pumpAndSettle();

      expect(find.text('You’re not going anywhere yet'), findsOneWidget);
      expect(find.text('Open the map'), findsOneWidget);
      expect(find.textContaining('two blocks'), findsOneWidget);
    });

    testWidgets('the error state is translated', (tester) async {
      await tester.pumpWidget(_host(_FakePartyRepository(const [], fail: true)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MY PARTIES'));
      await tester.pumpAndSettle();

      expect(find.text('We couldn’t load your events.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('actions and counts differ by privacy', () {
    testWidgets('a PUBLIC card offers both answers', (tester) async {
      await tester.pumpWidget(_card(
        _item(id: 'p1', title: 'Techno Monday', myRsvp: MpRsvp.interested)));
      await tester.pumpAndSettle();

      expect(find.text('Going'), findsOneWidget);
      expect(find.text('Interested ✓'), findsOneWidget);
      expect(find.text('Coming'), findsNothing);
    });

    testWidgets('a PRIVATE card offers exactly one, and it is not Interested', (tester) async {
      // The server refuses an 'interested' row on a private party
      // (20260825090050). Offering the button would be an affordance that
      // comes back 42501, so its ABSENCE is the assertion that matters.
      await tester.pumpWidget(_card(_item(id: 'p2', title: 'Rooftop', isPrivate: true)));
      await tester.pumpAndSettle();

      expect(find.text('Coming'), findsOneWidget);
      expect(find.text('Interested'), findsNothing);
      expect(find.text('Going'), findsNothing);
    });

    testWidgets('a PRIVATE card shows no attendance at all', (tester) async {
      await tester.pumpWidget(_card(_item(id: 'p2', title: 'Rooftop', isPrivate: true)));
      await tester.pumpAndSettle();

      // Both counters are NULL over the wire for a private row, so there is
      // no number here to forget to hide -- and none of the three spellings
      // the old hype bar used is on screen either.
      expect(find.textContaining('interested'), findsNothing);
      expect(find.textContaining('here now'), findsNothing);
      expect(find.text('HYPE NOW'), findsNothing);
      expect(find.byIcon(Icons.local_fire_department), findsNothing);
    });

    testWidgets('a PUBLIC card shows the real counter, labelled by tense', (tester) async {
      await tester.pumpWidget(_card(_item(id: 'p1', title: 'Techno Monday')));
      await tester.pumpAndSettle();
      expect(find.text('12 interested'), findsOneWidget);

      // Live flips which counter is read AND the noun that goes with it, so
      // the number and its label cannot disagree about which one it is.
      await tester.pumpWidget(_card(_item(id: 'p1', title: 'Techno Monday', isLive: true)));
      await tester.pumpAndSettle();
      expect(find.text('4 here now'), findsOneWidget);
      expect(find.text('12 interested'), findsNothing);
    });

    testWidgets('answering reports the tap up, it does not mutate a store', (tester) async {
      final taps = <MpRsvp>[];
      await tester.pumpWidget(_card(
        _item(id: 'p1', title: 'Techno Monday', myRsvp: MpRsvp.interested),
        onRsvp: taps.add,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Going'));
      await tester.pumpAndSettle();

      expect(taps, [MpRsvp.going]);
    });

    testWidgets('tapping the selected answer reports it, which is the un-RSVP', (tester) async {
      // Un-tap is a DELETE of the row, not a third enum value -- rsvp_status
      // has exactly two values and 22_private asserts it stays that way. The
      // card reports the SAME status it already holds, and the repository
      // turns "same as current" into the delete.
      final taps = <MpRsvp>[];
      await tester.pumpWidget(_card(
        _item(id: 'p2', title: 'Rooftop', isPrivate: true, myRsvp: MpRsvp.going),
        onRsvp: taps.add,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Coming ✓'), findsOneWidget);
      await tester.tap(find.text('Coming ✓'));
      await tester.pumpAndSettle();

      expect(taps, [MpRsvp.going]);
    });

    testWidgets('the screen turns a repeat answer into a withdrawal', (tester) async {
      // The other half of the pair above: the card reports, the SCREEN decides
      // what it costs. `current` is what tells the repository this is a delete.
      final repo = _FakePartyRepository(const [], pages: {
        PartySort.soonest: [_item(id: 'p9', title: 'Techno Monday', myRsvp: MpRsvp.going)],
      });
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Going ✓'));
      await tester.pumpAndSettle();

      expect(repo.rsvpWrites.single.partyId, 'p9');
      expect(repo.rsvpWrites.single.status, MpRsvp.going);
      expect(repo.rsvpWrites.single.current, MpRsvp.going);
    });

    testWidgets('an RSVP saved on ANOTHER tab reloads MY PARTIES and relights the card', (tester) async {
      // The tabs live in an IndexedStack, so this screen is never rebuilt by
      // the map sheet writing an rsvp. rsvpChanges is the only way it hears.
      final repo = _FakePartyRepository(const [], pages: {
        PartySort.soonest: [_item(id: 'p9', title: 'Techno Monday')],
      });
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      final before = repo.rsvpFetches;
      expect(find.text('Going ✓'), findsNothing);

      rsvpChanges.value = const RsvpChange(partyId: 'p9', status: MpRsvp.going);
      await tester.pumpAndSettle();

      expect(repo.rsvpFetches, before + 1);
      expect(find.text('Going ✓'), findsOneWidget);
    });

    testWidgets('only a PRIVATE rsvp row opens a chat', (tester) async {
      // A public party has no group chat since 20260825094044. The row is
      // inert rather than opening a screen that could never load a message --
      // and the rule behind it is can_chat_in_party, not this guard: a
      // hand-rolled insert is refused by the messages policy either way.
      final now = DateTime.now();
      await tester.pumpWidget(_host(_FakePartyRepository([
        _rsvp(title: 'Public one', startsAt: now.add(const Duration(hours: 2))),
        _rsvp(
          title: 'Private one',
          startsAt: now.add(const Duration(hours: 3)),
          isPrivate: true,
        ),
      ])));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MY PARTIES'));
      await tester.pumpAndSettle();

      GestureDetector rowFor(String title) => tester.widget<GestureDetector>(
            find.ancestor(of: find.text(title), matching: find.byType(GestureDetector)).first,
          );

      expect(rowFor('Public one').onTap, isNull);
      expect(rowFor('Private one').onTap, isNotNull);
    });

    testWidgets('the group chat entry is absent on a public detail sheet', (tester) async {
      await tester.pumpWidget(_card(_item(id: 'p1', title: 'Techno Monday')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Techno Monday'));
      await tester.pumpAndSettle();

      expect(find.byType(PartyDetailSheet), findsOneWidget);
      expect(find.text('Group chat'), findsNothing);
      // Directions stays, so this is the chat entry going rather than the
      // whole button row.
      expect(find.text('Directions'), findsOneWidget);
    });

    testWidgets('the group chat entry is present on a private detail sheet', (tester) async {
      await tester.pumpWidget(_card(_item(id: 'p2', title: 'Rooftop', isPrivate: true)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rooftop'));
      await tester.pumpAndSettle();

      // Scoped to the SHEET. The card underneath carries its own 'Group chat'
      // pill, so an unscoped find.text matches twice and the assertion would
      // pass on a sheet that had lost its button entirely.
      expect(
        find.descendant(of: find.byType(PartyDetailSheet), matching: find.text('Group chat')),
        findsOneWidget,
      );
      expect(find.text('Directions'), findsOneWidget);
    });

    testWidgets('the card carries a group chat pill on a private party only', (tester) async {
      await tester.pumpWidget(_card(_item(id: 'p2', title: 'Rooftop', isPrivate: true)));
      await tester.pumpAndSettle();

      expect(find.byType(PartyDetailSheet), findsNothing);
      expect(find.text('Group chat'), findsOneWidget);
      expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
    });

    testWidgets('a public card carries no chat pill', (tester) async {
      await tester.pumpWidget(_card(_item(id: 'p1', title: 'Techno Monday')));
      await tester.pumpAndSettle();

      expect(find.text('Group chat'), findsNothing);
      expect(find.byIcon(Icons.forum_outlined), findsNothing);
    });

    testWidgets('the private detail sheet hides the attendance chip and offers one action', (tester) async {
      await tester.pumpWidget(_card(_item(id: 'p2', title: 'Rooftop', isPrivate: true)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rooftop'));
      await tester.pumpAndSettle();

      expect(find.byType(PartyDetailSheet), findsOneWidget);
      expect(find.text('Coming'), findsWidgets);
      expect(find.text('Interested'), findsNothing);
      expect(find.textContaining('interested'), findsNothing);
      expect(find.textContaining('here now'), findsNothing);
      // 'posters' ("11 people posting") did not survive mpParties -- no column
      // answers it. Asserted so it cannot come back as another invented count.
      expect(find.textContaining('people posting'), findsNothing);
    });

    testWidgets('the public detail sheet shows the attendance chip and both actions', (tester) async {
      await tester.pumpWidget(_card(_item(id: 'p1', title: 'Techno Monday')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Techno Monday'));
      await tester.pumpAndSettle();

      expect(find.byType(PartyDetailSheet), findsOneWidget);
      expect(find.text('12 interested'), findsWidgets);
      expect(find.text('Going'), findsWidgets);
    });
  });

  // The feature the RPC exists for. These assert that the ORDER is the
  // server's answer and that changing it goes back to the server -- a
  // client-side sort over a loaded page would satisfy any assertion about
  // what is on screen and none of these.
  group('the ALL PARTIES sort is the servers', () {
    testWidgets('both sort options are offered, soonest first', (tester) async {
      final repo = _FakePartyRepository(const [], pages: {
        PartySort.soonest: [_item(id: 'p1', title: 'A')],
      });
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();

      expect(find.text('Soonest'), findsOneWidget);
      expect(find.text('Most interested'), findsOneWidget);
      expect(repo.sortsRequested, [PartySort.soonest]);
    });

    testWidgets('picking a sort REFETCHES rather than reordering', (tester) async {
      // The two pages hold different ROWS, not the same rows in a different
      // order -- so a screen that sorted locally would still be showing the
      // soonest row after the tap, and this fails.
      final repo = _FakePartyRepository(const [], pages: {
        PartySort.soonest: [_item(id: 'p1', title: 'Soonest row')],
        PartySort.interested: [_item(id: 'p2', title: 'Most interested row')],
      });
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();

      expect(find.text('Soonest row'), findsOneWidget);

      await tester.tap(find.text('Most interested'));
      await tester.pumpAndSettle();

      expect(repo.sortsRequested, [PartySort.soonest, PartySort.interested]);
      expect(find.text('Most interested row'), findsOneWidget);
      expect(find.text('Soonest row'), findsNothing);
    });

    testWidgets('re-picking the sort already selected does not refetch', (tester) async {
      final repo = _FakePartyRepository(const [], pages: {
        PartySort.soonest: [_item(id: 'p1', title: 'A')],
      });
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Soonest'));
      await tester.pumpAndSettle();

      expect(repo.sortsRequested, [PartySort.soonest]);
    });

    testWidgets('the order on screen is the order the server returned', (tester) async {
      // Deliberately NOT sorted by any field the client could sort on: the
      // interested counts ascend down the list while the titles descend, so a
      // local sort on either field produces a different result.
      final repo = _FakePartyRepository(const [], pages: {
        // Two rows, not three: the test viewport is 600px and the cards are
        // ~250px, so a third is never built by the lazy ListView and could not
        // be asserted on without scrolling. Two is enough -- the counts ascend
        // while the list descends, so a local sort by either field flips them.
        PartySort.interested: [
          _item(id: 'p1', title: 'Zebra', interested: 1),
          _item(id: 'p2', title: 'Yak', interested: 5),
        ],
      });
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Most interested'));
      await tester.pumpAndSettle();

      final titles = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((t) => t == 'Zebra' || t == 'Yak')
          .toList();
      expect(titles, ['Zebra', 'Yak']);
    });

    testWidgets('a private row in the interested list shows no count', (tester) async {
      // The side channel, from the client end. The server groups private rows
      // rather than ranking them and sends NULL for both counters; this is the
      // assertion that the card does not invent one back.
      final repo = _FakePartyRepository(const [], pages: {
        PartySort.interested: [
          _item(id: 'p2', title: 'Private one', isPrivate: true),
          _item(id: 'p1', title: 'Public one', interested: 40),
        ],
      });
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Most interested'));
      await tester.pumpAndSettle();

      expect(find.text('Private one'), findsOneWidget);
      expect(find.text('40 interested'), findsOneWidget);
      // The private card is ABOVE the public one, so a card that printed a 0
      // would be the first attendance line on screen -- exactly the confident
      // zero that 20260825090051 returns NULL to prevent. Asserted as exact
      // strings rather than textContaining: the sort chip itself reads "Most
      // interested", so a substring match finds it and passes either way.
      expect(find.text('0 interested'), findsNothing);
      expect(find.text('0 here now'), findsNothing);
      expect(find.textContaining('here now'), findsNothing);
    });

    testWidgets('a failed first page is an error state with a retry', (tester) async {
      final repo = _FakePartyRepository(const [], listFails: true);
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();

      expect(find.textContaining('load the parties'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}
