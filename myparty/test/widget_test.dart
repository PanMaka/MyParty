import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/data/social_repository.dart';
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

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders the followed state for an already-followed profile', (tester) async {
    final repo = _FakeSocialRepository(initiallyFollowing: true);

    await tester.pumpWidget(_wrap(
      FollowButton(targetUserId: 'u1', repository: repo),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Ακολουθείς'), findsOneWidget);
  });

  testWidgets('tapping follows and flips the label', (tester) async {
    final repo = _FakeSocialRepository();

    await tester.pumpWidget(_wrap(
      FollowButton(targetUserId: 'u1', repository: repo),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Ακολούθησε'), findsOneWidget);

    await tester.tap(find.byType(FollowButton));
    await tester.pumpAndSettle();

    expect(repo.followCalls, 1);
    expect(find.text('Ακολουθείς'), findsOneWidget);
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
    expect(find.text('Ακολούθησε'), findsOneWidget);
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
    expect(find.text('Ακολούθησε'), findsOneWidget);
    expect(find.text('Δεν έγινε. Δοκίμασε ξανά.'), findsOneWidget);
  });
}
