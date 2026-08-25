import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:myparty/data/party_repository.dart';
import 'package:myparty/models/mp_party.dart';
import 'package:myparty/models/rsvp_party.dart';
import 'package:myparty/state/mp_store.dart';
import 'package:myparty/ui/screens/events_screen.dart';
import 'package:myparty/ui/widgets/party_card.dart';

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
        _rsvp(
          title: 'Later this week',
          startsAt: now.add(const Duration(days: 3)),
          isPrivate: true,
          status: 'interested',
          going: 0,
          interested: 7,
        ),
        _rsvp(title: 'Much later', startsAt: now.add(const Duration(days: 20))),
      ])));
      await tester.pumpAndSettle();

      await tester.tap(find.text('MINE'));
      await tester.pumpAndSettle();

      expect(find.text('TONIGHT'), findsOneWidget);
      expect(find.text('THIS WEEK'), findsOneWidget);
      expect(find.text('LATER'), findsOneWidget);

      expect(find.text('GOING'), findsNWidgets(2));
      expect(find.text('INTERESTED'), findsOneWidget);

      // PrivacyBadge is shared with six untranslated surfaces, so this screen
      // opts in per call site rather than flipping the widget's default.
      expect(find.text('PRIVATE'), findsOneWidget);
      expect(find.text('PUBLIC'), findsNWidgets(2));

      expect(find.text('4 going'), findsNWidgets(2));
      expect(find.text('7 interested'), findsOneWidget);

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
}
