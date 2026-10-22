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
import 'package:myparty/ui/screens/follow_suggestions_screen.dart';
import 'package:myparty/ui/screens/profile_screen.dart';
import 'package:myparty/ui/widgets/people_you_may_know.dart';
import 'package:myparty/ui/widgets/user_link.dart';

/// Phase 48's client: PEOPLE YOU MAY KNOW on the owner's profile, See all,
/// follow and dismiss (with Undo) from either, and the reason text.

FollowSuggestion _s(
  String id, {
  SuggestionReason reason = SuggestionReason.mutuals,
  bool followsYou = false,
  int mutualCount = 1,
  List<String> names = const ['maria'],
  int rank = 0,
}) {
  final tier = switch (reason) {
    SuggestionReason.mutuals => 1,
    SuggestionReason.followsYou => 2,
    SuggestionReason.popular => 3,
  };
  return FollowSuggestion(
    userId: id,
    username: 'user_$id',
    reason: reason,
    followsYou: followsYou,
    mutualCount: reason == SuggestionReason.mutuals ? mutualCount : 0,
    mutualUsernames: reason == SuggestionReason.mutuals ? names : const [],
    cursor: SuggestionCursor(tier: tier, rank: rank, userId: id),
  );
}

/// Stands in for the server: serves [all] in order, page by page after the
/// cursor's user id, minus what has been dismissed or followed — which is what
/// `get_follow_suggestions` would leave out on the next call.
class _FakeSocial extends SocialRepository {
  _FakeSocial(this.all, {this.failDismiss = false, this.failFetch = false});

  final List<FollowSuggestion> all;
  final bool failDismiss;
  final bool failFetch;

  final Set<String> dismissed = {};
  final Set<String> followed = {};

  /// Every network call, in order.
  final List<String> calls = [];

  @override
  Future<List<FollowSuggestion>> fetchFollowSuggestions({SuggestionCursor? after, int limit = 20}) async {
    calls.add('fetch:${after?.userId}:$limit');
    if (failFetch) throw Exception('offline');
    final visible = all.where((s) => !dismissed.contains(s.userId) && !followed.contains(s.userId)).toList();
    final start = after == null ? 0 : visible.indexWhere((s) => s.userId == after.userId) + 1;
    return visible.skip(start).take(limit).toList();
  }

  @override
  Future<void> writeDismissal(String targetUserId) async {
    calls.add('dismiss:$targetUserId');
    if (failDismiss) throw Exception('rejected');
    dismissed.add(targetUserId);
  }

  @override
  Future<void> deleteDismissal(String targetUserId) async {
    calls.add('undismiss:$targetUserId');
    dismissed.remove(targetUserId);
  }

  @override
  Future<bool> isFollowing(String targetUserId) async {
    calls.add('isFollowing:$targetUserId');
    return followed.contains(targetUserId);
  }

  @override
  Future<void> insertFollow(String targetUserId) async {
    calls.add('follow:$targetUserId');
    followed.add(targetUserId);
  }

  @override
  Future<void> deleteFollow(String targetUserId) async {
    calls.add('unfollow:$targetUserId');
    followed.remove(targetUserId);
  }

  @override
  Future<List<Profile>> fetchFollowing({String? userId}) async => const [];
}

class _FakeProfiles extends ProfileRepository {
  @override
  String? get currentUserId => 'me';

  @override
  Future<Profile?> fetchProfile({String? userId}) async =>
      Profile(id: userId ?? 'me', username: userId == null ? 'me_myself' : 'someone', followerCount: 5, followingCount: 3);

  @override
  Future<ProfileStats> fetchStats({String? userId}) async =>
      const ProfileStats(partiesAttended: 0, partiesHosted: 0, storiesPosted: 0);

  @override
  String? avatarUrl(String? path) => path == null ? null : 'https://stub.invalid/$path';
}

class _FakeParties extends PartyRepository {
  @override
  String? get currentUserId => 'me';

  @override
  Future<HostedParties> fetchMyHostedParties() async => const HostedParties(upcoming: [], past: []);

  @override
  Future<List<PartySummary>> fetchHostedParties({
    String? hostId,
    required PartyWindow window,
    bool publicOnly = false,
    int limit = 12,
  }) async =>
      const [];

  @override
  Future<Map<String, String>> signedCoverUrls(List<PartySummary> parties, {int expiresIn = 3600}) async => const {};
}

Future<void> _pumpProfile(WidgetTester tester, _FakeSocial social, {ProfileTarget target = const OwnProfile()}) async {
  await tester.pumpWidget(MaterialApp(
    home: ProfileScreen(target: target, repository: _FakeProfiles(), social: social, parties: _FakeParties()),
  ));
  await tester.pumpAndSettle();
}

Future<void> _pumpSeeAll(WidgetTester tester, _FakeSocial social) async {
  await tester.pumpWidget(MaterialApp(
    home: FollowSuggestionsScreen(social: social, avatarUrl: (_) => null),
  ));
  await tester.pumpAndSettle();
}

/// The ✕ / Follow button on See all's row for [id]; each row is keyed by id.
Finder _rowDismiss(String id) =>
    find.descendant(of: find.byKey(ValueKey(id)), matching: find.byTooltip('Dismiss'));
Finder _rowFollow(String id, String label) =>
    find.descendant(of: find.byKey(ValueKey(id)), matching: find.text(label));

/// The ✕ on the card or row showing [username].
Finder _dismissOf(String username, Type container) => find.descendant(
      of: find.ancestor(of: find.text(username), matching: find.byType(container)).first,
      matching: find.byTooltip('Dismiss'),
    );

/// The Follow button on the card or row showing [username].
Finder _followOf(String username, Type container, String label) => find.descendant(
      of: find.ancestor(of: find.text(username), matching: find.byType(container)).first,
      matching: find.text(label),
    );

void main() {
  group('reason text', () {
    test('mutuals: one name, then "and N others", two names on See all', () {
      expect(suggestionReasonText(_s('a')), 'Followed by maria');
      expect(suggestionReasonText(_s('a', mutualCount: 3, names: ['maria', 'nikos']), short: true),
          'Followed by maria and 2 others');
      expect(suggestionReasonText(_s('a', mutualCount: 2, names: ['maria', 'nikos']), short: true),
          'Followed by maria and 1 other');
      expect(suggestionReasonText(_s('a', mutualCount: 2, names: ['maria', 'nikos'])),
          'Followed by maria and nikos');
      expect(suggestionReasonText(_s('a', mutualCount: 4, names: ['maria', 'nikos'])),
          'Followed by maria, nikos and 2 others');
    });

    test('follows you, popular, and both labels when they apply together', () {
      expect(suggestionReasonText(_s('a', reason: SuggestionReason.followsYou, followsYou: true)), 'Follows you');
      expect(suggestionReasonText(_s('a', reason: SuggestionReason.popular)), 'Popular');
      expect(suggestionReasonText(_s('a', followsYou: true), short: true), 'Follows you · Followed by maria');
    });

    test('never names anyone the server did not send', () {
      // A count with no names (cannot happen today) says the number only.
      expect(suggestionReasonText(_s('a', mutualCount: 3, names: const [])), 'Followed by 3 people you follow');
    });
  });

  group('profile section', () {
    testWidgets('own profile: heading, cards, reasons and See all', (tester) async {
      final social = _FakeSocial([
        _s('a', mutualCount: 3, names: ['maria', 'nikos']),
        _s('b', reason: SuggestionReason.followsYou, followsYou: true),
        _s('c', reason: SuggestionReason.popular),
      ]);
      await _pumpProfile(tester, social);

      expect(find.text('PEOPLE YOU MAY KNOW'), findsOneWidget);
      expect(find.text('See all'), findsOneWidget);
      expect(find.byType(SuggestionCard), findsNWidgets(3));
      expect(find.text('Followed by maria and 2 others'), findsOneWidget);
      expect(find.text('Follows you'), findsOneWidget);
      expect(find.text('Popular'), findsOneWidget);
      // The cards know nobody on them is followed yet: no per-card lookup.
      expect(social.calls.where((c) => c.startsWith('isFollowing')), isEmpty);
    });

    testWidgets('not on somebody else\'s profile, and never fetched there', (tester) async {
      final social = _FakeSocial([_s('a')]);
      await _pumpProfile(tester, social, target: const OtherProfile('someone'));

      expect(find.text('PEOPLE YOU MAY KNOW'), findsNothing);
      expect(find.byType(SuggestionCard), findsNothing);
      expect(social.calls.where((c) => c.startsWith('fetch')), isEmpty);
    });

    testWidgets('hidden entirely when there is nobody to suggest', (tester) async {
      await _pumpProfile(tester, _FakeSocial(const []));
      expect(find.text('PEOPLE YOU MAY KNOW'), findsNothing);
      expect(find.text('See all'), findsNothing);
    });

    testWidgets('hidden, not an error, when the fetch fails', (tester) async {
      await _pumpProfile(tester, _FakeSocial([_s('a')], failFetch: true));
      expect(find.text('PEOPLE YOU MAY KNOW'), findsNothing);
      expect(find.textContaining('load'), findsNothing);
    });

    testWidgets('Follow flips the card to Following at once and the card stays', (tester) async {
      final social = _FakeSocial([_s('a'), _s('b')]);
      await _pumpProfile(tester, social);

      await tester.tap(_followOf('user_a', SuggestionCard, 'Follow'));
      await tester.pumpAndSettle();

      expect(social.calls, contains('follow:a'));
      expect(_followOf('user_a', SuggestionCard, 'Following'), findsOneWidget);
      expect(find.byType(SuggestionCard), findsNWidgets(2), reason: 'no refetch out from under the thumb');
      expect(_followOf('user_b', SuggestionCard, 'Follow'), findsOneWidget);
    });

    testWidgets('✕ removes the card at once; Undo puts it back in its place', (tester) async {
      final social = _FakeSocial([_s('a'), _s('b'), _s('c')]);
      await _pumpProfile(tester, social);

      await tester.tap(_dismissOf('user_b', SuggestionCard));
      await tester.pump();
      expect(find.text('user_b'), findsNothing, reason: 'gone before the server answered');
      await tester.pumpAndSettle();
      expect(social.calls, contains('dismiss:b'));
      expect(find.text('user_b won’t be suggested again'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(social.calls, contains('undismiss:b'));
      final xs = [
        for (final id in ['a', 'b', 'c']) tester.getTopLeft(find.text('user_$id')).dx,
      ];
      expect(xs[0] < xs[1] && xs[1] < xs[2], isTrue, reason: 'restored between a and c');
    });

    testWidgets('a refused dismissal brings the card back and says so', (tester) async {
      final social = _FakeSocial([_s('a'), _s('b')], failDismiss: true);
      await _pumpProfile(tester, social);

      await tester.tap(_dismissOf('user_a', SuggestionCard));
      await tester.pumpAndSettle();
      expect(find.text('user_a'), findsOneWidget);
      expect(find.text('Couldn’t remove this suggestion. Try again.'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('dismissing the last card hides the section', (tester) async {
      await _pumpProfile(tester, _FakeSocial([_s('a')]));
      await tester.tap(_dismissOf('user_a', SuggestionCard));
      await tester.pumpAndSettle();
      expect(find.text('PEOPLE YOU MAY KNOW'), findsNothing);
    });

    testWidgets('tapping a card opens that person\'s profile', (tester) async {
      final previous = userProfileScreenBuilder;
      addTearDown(() => userProfileScreenBuilder = previous);
      userProfileScreenBuilder = (target) => Scaffold(body: Text('profile of ${target.userIdOrNull}'));

      await _pumpProfile(tester, _FakeSocial([_s('a')]));
      await tester.tap(find.text('user_a'));
      await tester.pumpAndSettle();
      expect(find.text('profile of a'), findsOneWidget);
    });
  });

  group('See all', () {
    testWidgets('opens from the section and names two mutuals', (tester) async {
      await _pumpProfile(tester, _FakeSocial([_s('a', mutualCount: 3, names: ['maria', 'nikos'])]));
      await tester.tap(find.text('See all'));
      await tester.pumpAndSettle();

      expect(find.byType(FollowSuggestionsScreen), findsOneWidget);
      expect(find.text('People you may know'), findsOneWidget);
      expect(find.text('Followed by maria, nikos and 1 other'), findsOneWidget);
    });

    testWidgets('pages by keyset: the next page starts after the last row the server sent', (tester) async {
      final social = _FakeSocial([for (var i = 0; i < 25; i++) _s('p${i.toString().padLeft(2, '0')}')]);
      await _pumpSeeAll(tester, social);

      expect(social.calls.where((c) => c.startsWith('fetch')), ['fetch:null:20']);
      await tester.scrollUntilVisible(find.text('user_p24'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      expect(social.calls.where((c) => c.startsWith('fetch')), ['fetch:null:20', 'fetch:p19:20']);
      // Either side of the page boundary, once each: nothing skipped, nothing
      // repeated where the two pages meet.
      for (final id in ['user_p19', 'user_p20', 'user_p24']) {
        expect(find.text(id), findsOneWidget, reason: id);
      }
      // And the first page is still the head of the list.
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(find.text('user_p00'), findsOneWidget);
    });

    testWidgets('empty state', (tester) async {
      await _pumpSeeAll(tester, _FakeSocial(const []));
      expect(find.text('No suggestions right now.'), findsOneWidget);
    });

    testWidgets('follow and dismiss with Undo work here too', (tester) async {
      final social = _FakeSocial([_s('a'), _s('b')]);
      await _pumpSeeAll(tester, social);

      await tester.tap(_rowFollow('a', 'Follow'));
      await tester.pumpAndSettle();
      expect(social.calls, contains('follow:a'));
      expect(_rowFollow('a', 'Following'), findsOneWidget);

      await tester.tap(_rowDismiss('b'));
      await tester.pumpAndSettle();
      expect(find.text('user_b'), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('user_b'), findsOneWidget);
      expect(social.calls, containsAllInOrder(['dismiss:b', 'undismiss:b']));
    });

    testWidgets('a dismissal on See all leaves the profile row too', (tester) async {
      final social = _FakeSocial([_s('a'), _s('b')]);
      await _pumpProfile(tester, social);
      expect(find.byType(SuggestionCard), findsNWidgets(2));

      await tester.tap(find.text('See all'));
      await tester.pumpAndSettle();
      await tester.tap(_rowDismiss('a'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(SuggestionCard), findsOneWidget);
      expect(find.descendant(of: find.byType(SuggestionCard), matching: find.text('user_a')), findsNothing);
    });

    testWidgets('a follow on See all shows as Following on the profile row', (tester) async {
      final social = _FakeSocial([_s('a')]);
      await _pumpProfile(tester, social);

      await tester.tap(find.text('See all'));
      await tester.pumpAndSettle();
      await tester.tap(_rowFollow('a', 'Follow'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(_followOf('user_a', SuggestionCard, 'Following'), findsOneWidget);
    });
  });
}
