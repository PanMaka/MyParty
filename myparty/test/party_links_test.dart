import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myparty/data/party_repository.dart';
import 'package:myparty/models/party_list_item.dart';
import 'package:myparty/services/party_links.dart';
import 'package:myparty/ui/widgets/party_detail_sheet.dart';
import 'package:myparty/ui/widgets/party_link_handler.dart';
import 'package:myparty/utils/share_party.dart';

const _id = '3f2a9c1e-7b4d-4e8a-9c2f-1d5e6a7b8c90';

PartyListItem _item({bool isPrivate = false}) => PartyListItem(
      partyId: _id,
      title: 'Rooftop Pregame',
      description: 'Bring ice.',
      startsAt: DateTime.now().add(const Duration(days: 2)),
      endsAt: null,
      area: null,
      coverPath: null,
      isPrivate: isPrivate,
      isSponsored: false,
      hostId: 'host',
      hostUsername: 'zoi',
      isLive: false,
      goingCount: isPrivate ? null : 4,
      interestedCount: isPrivate ? null : 9,
      myRsvp: null,
      isInvited: isPrivate,
      sortGroup: 0,
      sortRank: 0,
    );

class _FakePartyRepository extends PartyRepository {
  _FakePartyRepository({this.party, this.fail = false});

  final PartyListItem? party;
  final bool fail;
  final fetched = <String>[];

  @override
  Future<PartyListItem?> fetchParty(String partyId) async {
    fetched.add(partyId);
    if (fail) throw StateError('offline');
    return party;
  }

  @override
  Future<String?> signedCoverUrl(String? coverPath, {int expiresIn = 3600}) async => null;
}

Future<void> _mount(WidgetTester tester, _FakePartyRepository repo, ValueNotifier<String?> pending) async {
  await tester.pumpWidget(MaterialApp(
    home: PartyLinkHandler(
      repository: repo,
      pending: pending,
      child: const Scaffold(body: Text('home')),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('PartyLinkHandler', () {
    testWidgets('a link that arrived before sign-in opens on first build', (tester) async {
      final repo = _FakePartyRepository(party: _item());
      final pending = ValueNotifier<String?>(_id);

      await _mount(tester, repo, pending);

      expect(repo.fetched, [_id]);
      expect(find.byType(PartyDetailSheet), findsOneWidget);
      expect(find.text('Rooftop Pregame'), findsOneWidget);
      expect(pending.value, isNull, reason: 'consumed, so it is never opened twice');
    });

    testWidgets('a link arriving while signed in opens straight away', (tester) async {
      final repo = _FakePartyRepository(party: _item());
      final pending = ValueNotifier<String?>(null);
      await _mount(tester, repo, pending);
      expect(find.byType(PartyDetailSheet), findsNothing);

      pending.value = _id;
      await tester.pumpAndSettle();

      expect(find.byType(PartyDetailSheet), findsOneWidget);
    });

    testWidgets('a party the viewer may not see says only "not available"', (tester) async {
      final repo = _FakePartyRepository(party: null);
      await _mount(tester, repo, ValueNotifier<String?>(_id));

      expect(find.byType(PartyDetailSheet), findsNothing);
      expect(find.text('This party isn’t available.'), findsOneWidget);
    });

    testWidgets('a failed fetch says exactly the same thing', (tester) async {
      // Distinguishing "error" from "no row" would let a stranger probe which
      // private party ids exist.
      final repo = _FakePartyRepository(fail: true);
      await _mount(tester, repo, ValueNotifier<String?>(_id));

      expect(find.text('This party isn’t available.'), findsOneWidget);
    });
  });

  group('PartyLinks.receive', () {
    tearDown(() => PartyLinks.pending.value = null);

    test('keeps the id of a party link', () {
      PartyLinks.receive(Uri.parse('https://mypartycorp.com/p/$_id'));
      expect(PartyLinks.pending.value, _id);
    });

    test('drops everything else, including an auth-callback lookalike', () {
      for (final link in [
        'https://mypartycorp.com/auth/callback#access_token=x&refresh_token=y&expires_in=3600&token_type=bearer',
        'myparty://p/$_id',
        'https://evil.com/p/$_id',
      ]) {
        PartyLinks.receive(Uri.parse(link));
        expect(PartyLinks.pending.value, isNull, reason: link);
      }
    });
  });

  group('sharing', () {
    test('a public party shares its title with the link', () {
      expect(
        partyShareText(partyId: _id, title: 'Rooftop Pregame', isPrivate: false),
        'Rooftop Pregame on MyParty: https://mypartycorp.com/p/$_id',
      );
    });

    test('a private party shares the link alone -- no title for the group chat to read', () {
      expect(
        partyShareText(partyId: _id, title: 'Rooftop Pregame', isPrivate: true),
        'https://mypartycorp.com/p/$_id',
      );
    });

    testWidgets('the detail sheet shares the party it shows', (tester) async {
      final shared = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PartyDetailSheet(
            item: _item(isPrivate: true),
            share: (text) async => shared.add(text),
          ),
        ),
      ));

      await tester.tap(find.byKey(const Key('party-detail-share')));
      await tester.pump();

      expect(shared, ['https://mypartycorp.com/p/$_id']);
    });
  });
}
