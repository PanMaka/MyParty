import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/feed_repository.dart';
import 'package:myparty/data/social_repository.dart';
import 'package:myparty/models/feed_post.dart';
import 'package:myparty/ui/screens/feed_screen.dart';
import 'package:myparty/ui/widgets/follow_button.dart';

/// Stands in for the real repository. Subclasses rather than implements so it
/// stays in sync with the real constructor. Every method that touches the
/// network is overridden, and `SocialRepository` resolves its client lazily,
/// so no Supabase client is ever constructed here.
class _FakeSocialRepository extends SocialRepository {
  _FakeSocialRepository({this.initiallyFollowing = false, this.failWrites = false});

  final bool initiallyFollowing;
  final bool failWrites;

  late bool following = initiallyFollowing;
  int followCalls = 0;
  int unfollowCalls = 0;

  @override
  Future<bool> isFollowing(String targetUserId) async => following;

  @override
  Future<void> follow(String targetUserId) async {
    followCalls += 1;
    if (failWrites) throw Exception('blocked');
    following = true;
  }

  @override
  Future<void> unfollow(String targetUserId) async {
    unfollowCalls += 1;
    if (failWrites) throw Exception('blocked');
    following = false;
  }
}

/// Same idea for the feed. `FeedRepository` also resolves its client lazily,
/// and `currentUserId` is overridden here for the same reason it exists on
/// the real class: there is no initialized Supabase client under
/// `flutter test`, so a widget that asked `Supabase.instance` directly would
/// throw during build.
class _FakeFeedRepository extends FeedRepository {
  _FakeFeedRepository({
    List<FeedPost> pages = const [],
    this.uid = 'me',
    this.failWrites = false,
  }) : _pages = List.of(pages);

  final List<FeedPost> _pages;
  final String? uid;
  final bool failWrites;

  final List<FeedPost?> cursors = [];
  int likeCalls = 0;
  int unlikeCalls = 0;

  @override
  String? get currentUserId => uid;

  @override
  Future<List<FeedPost>> fetchFeed({FeedPost? after, int limit = 20}) async {
    cursors.add(after);
    if (after == null) return _pages;
    // Only ever one page in these fixtures; a second call returning empty is
    // what tells the screen it has reached the end.
    return const [];
  }

  @override
  Future<void> like(String postId) async {
    likeCalls += 1;
    if (failWrites) throw Exception('gone');
  }

  @override
  Future<void> unlike(String postId) async {
    unlikeCalls += 1;
    if (failWrites) throw Exception('gone');
  }
}

FeedPost _post({
  String id = 'p1',
  String authorId = 'me',
  String body = 'γεια',
  int likeCount = 0,
  bool likedByMe = false,
  int commentCount = 0,
}) {
  return FeedPost(
    postId: id,
    partyId: 'party1',
    partyTitle: 'Ταράτσα',
    partyIsPrivate: false,
    authorId: authorId,
    authorUsername: 'someone',
    body: body,
    mediaPath: null,
    likeCount: likeCount,
    commentCount: commentCount,
    likedByMe: likedByMe,
    createdAt: DateTime.now().toUtc(),
  );
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders the followed state for an already-followed profile', (tester) async {
    final repo = _FakeSocialRepository(initiallyFollowing: true);

    await tester.pumpWidget(_wrap(
      FollowButton(targetUserId: 'u1', repository: repo),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Following'), findsOneWidget);
  });

  testWidgets('tapping follows and flips the label', (tester) async {
    final repo = _FakeSocialRepository();

    await tester.pumpWidget(_wrap(
      FollowButton(targetUserId: 'u1', repository: repo),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Follow'), findsOneWidget);

    await tester.tap(find.byType(FollowButton));
    await tester.pumpAndSettle();

    expect(repo.followCalls, 1);
    expect(find.text('Following'), findsOneWidget);
  });

  testWidgets('tapping again unfollows', (tester) async {
    final repo = _FakeSocialRepository(initiallyFollowing: true);

    await tester.pumpWidget(_wrap(
      FollowButton(targetUserId: 'u1', repository: repo),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FollowButton));
    await tester.pumpAndSettle();

    expect(repo.unfollowCalls, 1);
    expect(find.text('Follow'), findsOneWidget);
  });

  testWidgets('rolls the optimistic flip back when the write is rejected', (tester) async {
    // This is the block case: the follows INSERT policy rejects with 42501,
    // so the button must not be left claiming a follow that does not exist.
    final repo = _FakeSocialRepository(failWrites: true);

    await tester.pumpWidget(_wrap(
      FollowButton(targetUserId: 'u1', repository: repo),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FollowButton));
    await tester.pumpAndSettle();

    expect(repo.followCalls, 1);
    expect(find.text('Follow'), findsOneWidget);
    expect(find.text('That did not work. Try again.'), findsOneWidget);
  });

  testWidgets('the feed renders real posts, not the old hardcoded card', (tester) async {
    final repo = _FakeFeedRepository(pages: [
      _post(id: 'p1', body: 'πρώτο'),
      _post(id: 'p2', body: 'δεύτερο'),
    ]);

    await tester.pumpWidget(MaterialApp(home: FeedScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.text('πρώτο'), findsOneWidget);
    expect(find.text('δεύτερο'), findsOneWidget);
    // The hardcoded card's copy is gone for good. ("Kápsimo" is gone from the
    // story row too as of Phase 5 — see story_test.dart, which asserts that
    // separately against real rails.)
    expect(find.textContaining('Γέμισε μέχρι τις 04:00'), findsNothing);
  });

  testWidgets('an empty feed explains itself instead of rendering nothing', (tester) async {
    final repo = _FakeFeedRepository();

    await tester.pumpWidget(MaterialApp(home: FeedScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Ήσυχα εδώ.'), findsOneWidget);
  });

  testWidgets('liking moves the counter optimistically and writes through', (tester) async {
    final repo = _FakeFeedRepository(pages: [_post(likeCount: 3)]);

    await tester.pumpWidget(MaterialApp(home: FeedScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.text('3'), findsOneWidget);

    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();

    expect(repo.likeCalls, 1);
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('a rejected like rolls the counter back', (tester) async {
    // The party can stop being accessible between the fetch and the tap — a
    // block, or the host flipping it private — and the post_likes INSERT
    // policy then rejects with 42501. The pill must not keep the phantom.
    final repo = _FakeFeedRepository(pages: [_post(likeCount: 3)], failWrites: true);

    await tester.pumpWidget(MaterialApp(home: FeedScreen(repository: repo)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();

    expect(repo.likeCalls, 1);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Δεν έγινε. Δοκίμασε ξανά.'), findsOneWidget);
  });

  testWidgets('someone else\'s post offers the report actions', (tester) async {
    final repo = _FakeFeedRepository(pages: [_post(authorId: 'them')], uid: 'me');

    await tester.pumpWidget(MaterialApp(home: FeedScreen(repository: repo)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(find.text('Αναφορά δημοσίευσης'), findsOneWidget);
    expect(find.text('Αναφορά χρήστη'), findsOneWidget);
    expect(find.text('Διαγραφή'), findsNothing);
  });

  testWidgets('your own post offers delete instead', (tester) async {
    // No point reporting yourself; hide_post is what your own post gets.
    final repo = _FakeFeedRepository(pages: [_post(authorId: 'me')], uid: 'me');

    await tester.pumpWidget(MaterialApp(home: FeedScreen(repository: repo)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(find.text('Διαγραφή'), findsOneWidget);
    expect(find.text('Αναφορά δημοσίευσης'), findsNothing);
  });

  testWidgets('the second page is fetched by keyset cursor, never an offset', (tester) async {
    // 20 posts is a full page, so the screen believes there may be more and
    // pages on scroll — passing the last row it holds as the cursor.
    final repo = _FakeFeedRepository(
      pages: [for (var i = 0; i < 20; i++) _post(id: 'p$i', body: 'post $i')],
    );

    await tester.pumpWidget(MaterialApp(home: FeedScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(repo.cursors, [null]);

    // By key: the story row above the feed is a ListView too.
    await tester.fling(find.byKey(const ValueKey('feed-list')), const Offset(0, -6000), 4000);
    await tester.pumpAndSettle();

    expect(repo.cursors.length, 2);
    expect(repo.cursors[1]?.postId, 'p19');
  });
}
