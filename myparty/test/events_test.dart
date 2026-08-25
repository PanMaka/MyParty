import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:myparty/data/party_repository.dart';
import 'package:myparty/models/mp_party.dart';
import 'package:myparty/models/rsvp_party.dart';
import 'package:myparty/state/mp_store.dart';
import 'package:myparty/ui/screens/events_screen.dart';
import 'package:myparty/ui/widgets/party_card.dart';
import 'package:myparty/ui/widgets/party_detail_sheet.dart';

/// Answers [PartyRepository.fetchMyRsvps] from a list instead of the network.
///
/// Possible only because `PartyRepository` resolves its Supabase client
/// lazily — no client is ever constructed here, the same trick `map_test.dart`
/// relies on.
class _FakePartyRepository extends PartyRepository {
  _FakePartyRepository(this.rsvps, {this.fail = false});

  final List<RsvpParty> rsvps;
  final bool fail;

  @override
  Future<List<RsvpParty>> fetchMyRsvps() async {
    if (fail) throw Exception('nope');
    return rsvps;
  }
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

/// One PartyCard on its own, with a real store behind it.
///
/// `autoDecay: false` because MpStore otherwise runs a 2.6s periodic timer
/// that pumpAndSettle would wait on forever.
Widget _card(String partyId, {MpStore? store}) {
  return ChangeNotifierProvider<MpStore>(
    create: (_) => store ?? MpStore(autoDecay: false),
    child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: PartyCard(partyId: partyId)))),
  );
}

Widget _host(PartyRepository repository) {
  return ChangeNotifierProvider(
    create: (_) => MpStore(),
    child: MaterialApp(home: EventsScreen(repository: repository)),
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

      expect(find.text('MINE'), findsOneWidget);
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

    testWidgets('the mock party list renders English content', (tester) async {
      await tester.pumpWidget(_host(_FakePartyRepository(const [])));
      await tester.pumpAndSettle();

      // 'ALL PARTIES' is the default tab, so the mock cards are on screen.
      // They sort by sortKey, so Maria's is the first one rendered; the rest
      // are below the 600px test viewport and have to be scrolled to.
      expect(find.byType(PartyCard), findsWidgets);
      expect(find.text('Maria’s Birthday'), findsOneWidget);
      expect(find.text('HYPE NOW'), findsWidgets);

      await tester.scrollUntilVisible(find.text('Rooftop in Koukaki'), 300);
      expect(find.text('Rooftop in Koukaki'), findsOneWidget);
      expect(find.text('Dimitris Papadeas'), findsOneWidget);
      // The relative time the brief called out by name.
      expect(find.text('Tonight 23:30'), findsWidgets);

      // And nothing Greek survived in the data behind them.
      final greek = RegExp(r'[Ͱ-Ͽἀ-῿]');
      for (final party in mpParties.values) {
        for (final s in [party.name, party.host, party.hostSub, party.sub,
                         party.time, party.dist, party.crowd, party.imgLabel,
                         party.posters, party.desc, party.note]) {
          expect(greek.hasMatch(s), isFalse, reason: '"$s" is still Greek');
        }
      }
    });

    testWidgets('rsvp sections, badges and stamps are translated', (tester) async {
      final now = DateTime.now();
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
      ])));
      await tester.pumpAndSettle();

      await tester.tap(find.text('MINE'));
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

    testWidgets('the empty state is translated', (tester) async {
      await tester.pumpWidget(_host(_FakePartyRepository(const [])));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MINE'));
      await tester.pumpAndSettle();

      expect(find.text('You’re not going anywhere yet'), findsOneWidget);
      expect(find.text('Open the map'), findsOneWidget);
      expect(find.textContaining('two blocks'), findsOneWidget);
    });

    testWidgets('the error state is translated', (tester) async {
      await tester.pumpWidget(_host(_FakePartyRepository(const [], fail: true)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MINE'));
      await tester.pumpAndSettle();

      expect(find.text('We couldn’t load your events.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  // 'maria' and 'taratsa' are private in the mock data; 'vinyl' is public.
  group('actions and counts differ by privacy', () {
    testWidgets('a PUBLIC card offers both answers', (tester) async {
      // 'vinyl' is seeded as interested, so that button carries the tick and
      // the other does not -- both are present either way, which is the point:
      // switching has to stay one tap.
      await tester.pumpWidget(_card('vinyl'));
      await tester.pumpAndSettle();

      expect(find.text('Going'), findsOneWidget);
      expect(find.text('Interested ✓'), findsOneWidget);
      expect(find.text('Coming'), findsNothing);
    });

    testWidgets('a PRIVATE card offers exactly one, and it is not Interested', (tester) async {
      // The server refuses an 'interested' row on a private party
      // (20260825090050). Offering the button would be an affordance that
      // comes back 42501, so its ABSENCE is the assertion that matters.
      await tester.pumpWidget(_card('maria'));
      await tester.pumpAndSettle();

      expect(find.text('Coming'), findsOneWidget);
      expect(find.text('Interested'), findsNothing);
      expect(find.text('Going'), findsNothing);
    });

    testWidgets('a PRIVATE card shows no hype and no attendance', (tester) async {
      await tester.pumpWidget(_card('maria'));
      await tester.pumpAndSettle();

      // The hype bar is removed, not blanked: a percentage that moves when
      // people join is attendance one derivative removed.
      expect(find.text('HYPE NOW'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(find.byIcon(Icons.local_fire_department), findsNothing);
    });

    testWidgets('a PUBLIC card still shows hype', (tester) async {
      await tester.pumpWidget(_card('vinyl'));
      await tester.pumpAndSettle();

      expect(find.text('HYPE NOW'), findsOneWidget);
      expect(find.byIcon(Icons.local_fire_department), findsOneWidget);
    });

    testWidgets('a public party switches between the two answers', (tester) async {
      final store = MpStore(autoDecay: false);
      await tester.pumpWidget(_card('vinyl', store: store));
      await tester.pumpAndSettle();

      // Seeded as interested.
      expect(store.rsvpFor('vinyl'), MpRsvp.interested);
      expect(find.text('Interested ✓'), findsOneWidget);

      await tester.tap(find.text('Going'));
      await tester.pumpAndSettle();

      // Switched in place -- the mock analogue of `update rsvps set status`,
      // which the counter trigger handles as one delta rather than a
      // delete-then-insert.
      expect(store.rsvpFor('vinyl'), MpRsvp.going);
      expect(find.text('Going ✓'), findsOneWidget);
      expect(find.text('Interested'), findsOneWidget);
    });

    testWidgets('tapping the selected answer withdraws it entirely', (tester) async {
      // Un-tap is a DELETE of the row, not a third enum value. `rsvp_status`
      // has exactly two values and 22_private_party_counts_and_rsvp asserts
      // it stays that way -- so "not going" can only be the absence of a row.
      final store = MpStore(autoDecay: false);
      await tester.pumpWidget(_card('taratsa', store: store));
      await tester.pumpAndSettle();

      expect(store.rsvpFor('taratsa'), MpRsvp.going);
      expect(find.text('Coming ✓'), findsOneWidget);

      await tester.tap(find.text('Coming ✓'));
      await tester.pumpAndSettle();

      expect(store.rsvpFor('taratsa'), isNull);
      expect(find.text('Coming'), findsOneWidget);
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
      await tester.tap(find.text('MINE'));
      await tester.pumpAndSettle();

      GestureDetector rowFor(String title) => tester.widget<GestureDetector>(
            find.ancestor(of: find.text(title), matching: find.byType(GestureDetector)).first,
          );

      expect(rowFor('Public one').onTap, isNull);
      expect(rowFor('Private one').onTap, isNotNull);
    });

    testWidgets('the group chat entry is absent on a public detail sheet', (tester) async {
      await tester.pumpWidget(_card('vinyl'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Techno Monday · DJ Iris'));
      await tester.pumpAndSettle();

      expect(find.byType(PartyDetailSheet), findsOneWidget);
      expect(find.text('Group chat'), findsNothing);
      // Directions stays, so this is the chat entry going rather than the
      // whole button row.
      expect(find.text('Directions'), findsOneWidget);
    });

    testWidgets('the group chat entry is present on a private detail sheet', (tester) async {
      await tester.pumpWidget(_card('maria'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maria’s Birthday'));
      await tester.pumpAndSettle();

      expect(find.text('Group chat'), findsOneWidget);
      expect(find.text('Directions'), findsOneWidget);
    });

    testWidgets('the private detail sheet hides the crowd chip and offers one action', (tester) async {
      await tester.pumpWidget(_card('maria'));
      await tester.pumpAndSettle();

      // The cover opens the sheet. Tap the TITLE rather than the card's
      // centre -- a public card is taller, so its centre falls below the
      // cover's GestureDetector and the two cases would not be comparable.
      await tester.tap(find.text('Maria’s Birthday'));
      await tester.pumpAndSettle();

      expect(find.byType(PartyDetailSheet), findsOneWidget);
      expect(find.text('Coming'), findsWidgets);
      expect(find.text('Interested'), findsNothing);
      // '31 inside' is the mock crowd string for this party.
      expect(find.text('31 inside'), findsNothing);
      expect(find.textContaining('people posting'), findsNothing);
    });

    testWidgets('the public detail sheet still shows the crowd chip and both actions', (tester) async {
      await tester.pumpWidget(_card('vinyl'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Techno Monday · DJ Iris'));
      await tester.pumpAndSettle();

      expect(find.byType(PartyDetailSheet), findsOneWidget);
      expect(find.text('180 inside · 312 interested'), findsOneWidget);
      expect(find.text('46 people posting'), findsOneWidget);
      expect(find.text('Going'), findsWidgets);
    });
  });
}
