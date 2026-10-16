import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myparty/data/party_repository.dart';
import 'package:myparty/models/party_list_item.dart';
import 'package:myparty/services/party_links.dart';
import 'package:myparty/state/data_changes.dart';
import 'package:myparty/state/mp_store.dart';
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
  /// A viewer who hosts none of the fixtures, so every party opens its sheet
  /// rather than the host dashboard.
  @override
  String? get currentUserId => 'viewer';

  _FakePartyRepository({this.party, this.fail = false, this.redeemsTo, this.refusal});

  final PartyListItem? party;
  final bool fail;

  /// What redeeming an invite token answers: a party id, or [refusal].
  final String? redeemsTo;
  final InviteRefused? refusal;
  final redeemed = <String>[];
  final fetched = <String>[];

  @override
  Future<String> writeRedeem(String token) async {
    redeemed.add(token);
    if (refusal != null) throw refusal!;
    return redeemsTo!;
  }
  final rsvpWrites = <MpRsvp>[];

  @override
  Future<void> writeRsvp({required String partyId, required MpRsvp status, required MpRsvp? current}) async =>
      rsvpWrites.add(status);

  @override
  Future<PartyListItem?> fetchParty(String partyId) async {
    fetched.add(partyId);
    if (fail) throw StateError('offline');
    return party;
  }

  @override
  Future<String?> signedCoverUrl(String? coverPath, {int expiresIn = 3600}) async => null;
}

Future<void> _mount(
  WidgetTester tester,
  _FakePartyRepository repo,
  ValueNotifier<String?> pending, {
  ValueNotifier<String?>? pendingInvite,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: PartyLinkHandler(
      repository: repo,
      pending: pending,
      pendingInvite: pendingInvite ?? ValueNotifier<String?>(null),
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

  group('answering a linked party', () {
    testWidgets('Going on the sheet is saved and announced', (tester) async {
      // There is no list under a link's sheet to own the write; it used to
      // be opened with no callback, so the answer closed the sheet and went
      // nowhere.
      final repo = _FakePartyRepository(party: _item());
      final announced = <RsvpChanged>[];
      final sub = dataChanges.stream.listen((c) {
        if (c is RsvpChanged) announced.add(c);
      });
      addTearDown(sub.cancel);
      await _mount(tester, repo, ValueNotifier<String?>(_id));

      await tester.tap(find.descendant(of: find.byType(PartyDetailSheet), matching: find.text('Going')));
      await tester.pumpAndSettle();

      expect(repo.rsvpWrites, [MpRsvp.going]);
      expect(announced.single.partyId, _id);
      expect(announced.single.status, MpRsvp.going);
    });
  });

  testWidgets('a party you are invited to says who invited you; one you are not, says nothing', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PartyDetailSheet(item: _item(isPrivate: true)))));
    expect(find.text('Invited by @zoi'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PartyDetailSheet(item: _item()))));
    expect(find.byKey(const Key('invited-badge')), findsNothing);
  });

  group('invite links (/i#token)', () {
    testWidgets('a token waiting from before sign-in is redeemed, then its party opens', (tester) async {
      final repo = _FakePartyRepository(party: _item(isPrivate: true), redeemsTo: _id);
      final announced = <InviteRedeemed>[];
      final sub = dataChanges.stream.listen((c) {
        if (c is InviteRedeemed) announced.add(c);
      });
      addTearDown(sub.cancel);
      final pendingInvite = ValueNotifier<String?>(_token);

      await _mount(tester, repo, ValueNotifier<String?>(null), pendingInvite: pendingInvite);

      expect(repo.redeemed, [_token]);
      expect(repo.fetched, [_id], reason: 'opened through get_party, like any party link');
      expect(find.byType(PartyDetailSheet), findsOneWidget);
      expect(pendingInvite.value, isNull, reason: 'consumed, so it is never redeemed twice');
      expect(announced.single.partyId, _id, reason: 'MY PARTIES and the map hear about the new party');
    });

    testWidgets('every refusal reads the same', (tester) async {
      final repo = _FakePartyRepository(refusal: const InviteRefused());
      await _mount(tester, repo, ValueNotifier<String?>(null), pendingInvite: ValueNotifier<String?>(_token));

      expect(find.text('This invite link doesn’t work any more.'), findsOneWidget);
      expect(find.byType(PartyDetailSheet), findsNothing);
      expect(repo.fetched, isEmpty);
    });

    testWidgets('the rate limit is the one refusal that says something else', (tester) async {
      final repo = _FakePartyRepository(refusal: const InviteRefused(rateLimited: true));
      await _mount(tester, repo, ValueNotifier<String?>(null), pendingInvite: ValueNotifier<String?>(_token));

      expect(find.textContaining('Try again in a while'), findsOneWidget);
    });
  });

  group('PartyLinks.receive, invite links', () {
    tearDown(() {
      PartyLinks.pending.value = null;
      PartyLinks.pendingInvite.value = null;
    });

    test('an invite link becomes a pending token, not a pending party', () {
      PartyLinks.receive(Uri.parse('https://mypartycorp.com/i#$_token'));
      expect(PartyLinks.pendingInvite.value, _token);
      expect(PartyLinks.pending.value, isNull);
    });

    test('a party link still becomes a pending party', () {
      PartyLinks.receive(Uri.parse('https://mypartycorp.com/p/$_id'));
      expect(PartyLinks.pending.value, _id);
      expect(PartyLinks.pendingInvite.value, isNull);
    });
  });
}

/// 43 url-safe characters: the shape create_party_invite_link produces.
const _token = 'Ab3_Zx-9Ab3_Zx-9Ab3_Zx-9Ab3_Zx-9Ab3_Zx-9Ab3';
