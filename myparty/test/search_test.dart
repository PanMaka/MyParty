import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/party_repository.dart';
import 'package:myparty/data/social_repository.dart';
import 'package:myparty/models/map_party_pin.dart';
import 'package:myparty/models/profile.dart';
import 'package:myparty/ui/screens/search_screen.dart';

/// Records every query it was asked, so the tests can assert what was NOT sent
/// as well as what came back. Half of this screen's job is not querying.
class _FakeSocial extends SocialRepository {
  _FakeSocial({this.people = const []});

  final List<Profile> people;
  final List<String> queries = [];

  @override
  Future<List<Profile>> searchProfiles(String query, {int limit = 30}) async {
    queries.add(query);
    return people;
  }
}

class _FakeParties extends PartyRepository {
  _FakeParties({this.results = const PartySearchResults(upcoming: [], past: [])});

  final PartySearchResults results;
  final List<String> queries = [];

  @override
  Future<PartySearchResults> searchParties(String query, {int limit = 20}) async {
    queries.add(query);
    return results;
  }
}

Profile _profile(String username, {int followers = 0}) => Profile(
      id: 'aaaaaaaa-0000-0000-0000-${username.hashCode.abs().toString().padLeft(12, '0').substring(0, 12)}',
      username: username,
      followerCount: followers,
      followingCount: 0,
    );

MapPartyPin _pin(String title, {String? area, bool isPrivate = false}) => MapPartyPin(
      id: 'bbbbbbbb-0000-0000-0000-${title.hashCode.abs().toString().padLeft(12, '0').substring(0, 12)}',
      lat: 37.9758,
      lng: 23.7351,
      title: title,
      area: area,
      isPrivate: isPrivate,
      startsAt: DateTime.now().add(const Duration(days: 1)),
      endsAt: DateTime.now().add(const Duration(days: 1, hours: 6)),
    );

Future<void> _mount(WidgetTester tester, _FakeSocial social, _FakeParties parties) {
  return tester.pumpWidget(MaterialApp(
    home: SearchScreen(social: social, parties: parties),
  ));
}

/// Types [text] and lets the 300ms debounce elapse plus the async gap.
Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.pump(SearchScreen.debounce + const Duration(milliseconds: 20));
  await tester.pump();
}

void main() {
  group('SearchScreen: the query is withheld', () {
    testWidgets('nothing is sent below the minimum length', (tester) async {
      // The reason this matters is not politeness. search_parties is
      // deliberately UNCAPPED -- it returns every match rather than silently a
      // subset -- so a two-character prefix is a 295ms query for a result
      // nobody wants. The restraint lives here because the alternative was
      // dropping results in SQL.
      final social = _FakeSocial();
      final parties = _FakeParties();
      await _mount(tester, social, parties);

      await _type(tester, 'τα');

      expect(social.queries, isEmpty);
      expect(parties.queries, isEmpty);
    });

    testWidgets('and is sent at exactly the minimum length', (tester) async {
      final social = _FakeSocial();
      final parties = _FakeParties();
      await _mount(tester, social, parties);

      await _type(tester, 'τar');

      expect(social.queries, ['τar']);
      expect(parties.queries, ['τar']);
    });

    testWidgets('typing a word fires ONE query, not one per keystroke', (tester) async {
      final social = _FakeSocial();
      final parties = _FakeParties();
      await _mount(tester, social, parties);

      // Four characters typed inside the debounce window.
      for (final s in ['tar', 'tara', 'tarat', 'taratsa']) {
        await tester.enterText(find.byType(TextField), s);
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump(SearchScreen.debounce + const Duration(milliseconds: 20));
      await tester.pump();

      expect(social.queries, ['taratsa'],
          reason: 'only the settled query should reach the network');
    });

    testWidgets('deleting back under the minimum clears the results', (tester) async {
      // Otherwise the previous hits stay on screen under a two-character query
      // and read as "these are the matches for τα".
      final social = _FakeSocial(people: [_profile('taratsa_fan')]);
      final parties = _FakeParties();
      await _mount(tester, social, parties);

      await _type(tester, 'tar');
      expect(find.text('taratsa_fan'), findsOneWidget);

      await _type(tester, 'ta');
      expect(find.text('taratsa_fan'), findsNothing);
      expect(find.text('Γράψε κι άλλο'), findsOneWidget);
    });
  });

  group('SearchScreen: states', () {
    testWidgets('starts on the type-more hint, naming the minimum', (tester) async {
      await _mount(tester, _FakeSocial(), _FakeParties());

      expect(find.text('Γράψε κι άλλο'), findsOneWidget);
      expect(
        find.textContaining('${SearchScreen.minQueryLength} χαρακτήρες'),
        findsOneWidget,
        reason: 'the hint should state the actual threshold, not a hardcoded one',
      );
    });

    testWidgets('a real empty state, not an empty list', (tester) async {
      await _mount(tester, _FakeSocial(), _FakeParties());

      await _type(tester, 'zzzz');

      expect(find.text('Κανένα αποτέλεσμα'), findsOneWidget);
      // The prefix-only limitation is surfaced to the user rather than left as
      // a mystery, since it is a real narrowing versus what ilike did.
      expect(find.textContaining('αρχή της λέξης'), findsOneWidget);
    });

    testWidgets('an error is a message, not a blank screen', (tester) async {
      final parties = _FakeParties();
      final social = _ThrowingSocial();
      await _mount(tester, social, parties);

      await _type(tester, 'tar');

      expect(find.text('Κάτι πήγε στραβά'), findsOneWidget);
    });
  });

  group('SearchScreen: results', () {
    testWidgets('people and parties appear together, under their own headings',
        (tester) async {
      final social = _FakeSocial(people: [_profile('nikos_p', followers: 12)]);
      final parties = _FakeParties(
        results: PartySearchResults(
          upcoming: [_pin('Psiri Warehouse Rave', area: 'Ψυρρή')],
          past: [_pin('Γκάζι Warehouse Opening', area: 'Γκάζι')],
        ),
      );
      await _mount(tester, social, parties);

      await _type(tester, 'warehouse');

      expect(find.text('Άτομα'), findsOneWidget);
      expect(find.text('Επερχόμενα'), findsOneWidget);
      expect(find.text('Πέρασαν'), findsOneWidget);
      expect(find.text('nikos_p'), findsOneWidget);
      expect(find.text('Psiri Warehouse Rave'), findsOneWidget);
      expect(find.text('Γκάζι Warehouse Opening'), findsOneWidget);
    });

    testWidgets('a heading is absent when its group is empty', (tester) async {
      final parties = _FakeParties(
        results: PartySearchResults(upcoming: [_pin('Kolonaki Rooftop')], past: const []),
      );
      await _mount(tester, _FakeSocial(), parties);

      await _type(tester, 'kolonaki');

      expect(find.text('Επερχόμενα'), findsOneWidget);
      expect(find.text('Πέρασαν'), findsNothing);
      expect(find.text('Άτομα'), findsNothing);
    });

    testWidgets('the past/upcoming split is the SERVER\'s, not recomputed here',
        (tester) async {
      // Both fixtures start in the future, so any client-side recomputation of
      // "past" would put both in Επερχόμενα. They are grouped by which list the
      // repository returned them in, which is public.party_is_past() -- the
      // single definition. A second opinion in Dart would disagree with the
      // server about a party with no stated end (gotcha 21).
      final parties = _FakeParties(
        results: PartySearchResults(
          upcoming: [_pin('Future A')],
          past: [_pin('Filed As Past')],
        ),
      );
      await _mount(tester, _FakeSocial(), parties);

      await _type(tester, 'aaa');

      final pastHeading = tester.getTopLeft(find.text('Πέρασαν')).dy;
      expect(tester.getTopLeft(find.text('Filed As Past')).dy,
          greaterThan(pastHeading),
          reason: 'a future-dated party still renders under Πέρασαν when the '
              'server said is_past');
      expect(tester.getTopLeft(find.text('Future A')).dy, lessThan(pastHeading));
    });
  });

  group('SearchScreen: taps', () {
    testWidgets('tapping a party opens the same sheet the map opens', (tester) async {
      final parties = _FakeParties(
        results: PartySearchResults(upcoming: [_pin('Psiri Warehouse Rave')], past: const []),
      );
      await _mount(tester, _FakeSocial(), parties);
      await _type(tester, 'warehouse');

      await tester.tap(find.text('Psiri Warehouse Rave'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // MapPinSheet's report affordance is the marker that this is the real
      // sheet and not a lookalike built for search.
      expect(find.byTooltip('Αναφορά'), findsOneWidget);
    });
  });
}

class _ThrowingSocial extends _FakeSocial {
  @override
  Future<List<Profile>> searchProfiles(String query, {int limit = 30}) async {
    throw StateError('network down');
  }
}
